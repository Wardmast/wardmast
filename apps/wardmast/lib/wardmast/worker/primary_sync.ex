defmodule Wardmast.Worker.PrimarySync do
  @moduledoc """
  Safe fast-forward of a repo's *primary* local checkout (the shared
  directory registered in a workspace's `repo_paths` config —
  not a worker's isolated worktree) to the current `origin/<base_branch>`.

  `Wardmast.Worker.Worktree.fetch_origin/2` already refreshes the
  `origin/<base>` remote-tracking ref in a primary checkout before
  dispatching work into it, but that's refs-only — it never touches the
  checkout's own local branch, HEAD, index, or working tree. So a human's
  `git log`/`git status` on that checkout keeps drifting further behind
  `origin/<base>` with every merge (bd-bqqnin).

  `fast_forward/2` closes that gap, but only when it can do so with zero
  risk to a human's in-progress work — mirroring `git pull --ff-only`:

    * the checkout must currently be *on* `base_branch`
    * the working tree must have no uncommitted changes (staged, unstaged,
      or untracked)
    * the local branch must be a strict ancestor of the new
      `origin/<base_branch>` (a true fast-forward, never a merge/rebase)

  Any other situation — dirty tree, different branch, diverged history —
  is skipped, not errored: this is a best-effort convenience, never a gate
  that should fail a merge or clobber a human's checkout.
  """

  require Ash.Query
  require Logger

  alias Wardmast.Mergers
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.RepoConfig
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.TargetBranch
  alias Wardmast.Worker.Worktree
  alias Wardmast.Workers.Run

  @type path :: String.t()
  @type skip_reason ::
          :uncommitted_changes
          | :not_on_default_branch
          | :not_fast_forwardable

  @doc """
  Fast-forward `repo_path`'s local `base_branch` to `origin/base_branch`,
  iff that can be done as a safe, zero-risk fast-forward.

  Returns:

    * `:ok` — already up to date, or successfully fast-forwarded
    * `{:skipped, reason}` — left untouched; see `t:skip_reason/0`
    * `{:error, reason}` — a git operation itself failed (missing repo,
      missing `origin` remote, fetch failure, …)
  """
  @spec fast_forward(path(), String.t()) ::
          :ok | {:skipped, skip_reason()} | {:error, Worktree.error_reason()}
  def fast_forward(repo_path, base_branch)
      when is_binary(repo_path) and is_binary(base_branch) do
    with :ok <- Worktree.fetch_origin(repo_path, base_branch),
         {:ok, current} <- Worktree.current_branch(repo_path) do
      if current != base_branch do
        {:skipped, :not_on_default_branch}
      else
        with_clean_tree(repo_path, base_branch)
      end
    end
  end

  @doc """
  The opt-in, best-effort sync every merge-success path runs after a PR lands
  (bd-2rdfsh): fast-forward the primary checkout of `repo` to `origin/<base>`
  when `merge.auto_sync_primary` is on for that repo's effective merge config.

  This is the one implementation behind every merge path: the MergeQueue's own
  close, and the Watchdog / Driver / MergedPRFinalizer finalizers (which reach
  it through `sync_after_merge/1`). Before it was shared only the MergeQueue
  synced, yet a ReviewGate-approved ticket is merged by the Watchdog, which the
  queue then skips as already closed. So the primary's local target branch
  silently stopped advancing.

  Never raises and never blocks the caller: returns `:ok` whatever happened,
  logging a skip or failure at warning level (a stale local target branch is
  what once let an empty branch pass the commit gate). `label` names the
  caller's task in those log lines.
  """
  @spec sync_after_merge(Workspace.t() | nil, String.t() | nil, String.t() | nil, String.t()) ::
          :ok
  def sync_after_merge(%Workspace{} = workspace, repo, base, label) do
    if Workspace.auto_sync_primary?(Mergers.scope(workspace, repo)) do
      sync_primary(workspace, repo, base, label)
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "PrimarySync.sync_after_merge: swallowed exception for #{label}: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  def sync_after_merge(_workspace, _repo, _base, _label), do: :ok

  @doc """
  `sync_after_merge/4` for a merged `Issue`: the workspace, the repo the task
  was worked in (its latest run's, else its own `repo`) and the integration
  branch (`Wardmast.Worker.TargetBranch`) are resolved from the ticket, the
  same chain the MergeQueue uses. Best-effort; always `:ok`.
  """
  @spec sync_after_merge(Issue.t()) :: :ok
  def sync_after_merge(%Issue{workspace_id: ws_id} = issue) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, workspace} ->
        repo = latest_run_repo(issue.id) || blank_to_nil(issue.repo)
        base = TargetBranch.resolve(issue, repo: repo)
        sync_after_merge(workspace, repo, base, "task=#{issue.id}")

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def sync_after_merge(_issue), do: :ok

  defp sync_primary(workspace, repo, base, label) do
    case primary_repo_path(workspace, repo) do
      nil ->
        Logger.info(
          "PrimarySync: primary-checkout sync skipped for #{label} " <>
            "(no repo_paths entry for #{inspect(repo)})"
        )

      repo_path when is_binary(base) ->
        case fast_forward(repo_path, base) do
          :ok ->
            :ok

          {:skipped, reason} ->
            Logger.warning(
              "PrimarySync: primary-checkout sync skipped for #{repo_path} (#{reason}); " <>
                "its local #{base} stays behind origin/#{base} until it is fast-forwarded"
            )

          {:error, reason} ->
            Logger.warning(
              "PrimarySync: primary-checkout sync failed for #{repo_path}: #{inspect(reason)}"
            )
        end

      repo_path ->
        Logger.info(
          "PrimarySync: primary-checkout sync skipped for #{label} " <>
            "path=#{repo_path} (no base branch resolved)"
        )
    end
  end

  defp primary_repo_path(%Workspace{config: %{} = config}, repo)
       when is_binary(repo) and repo != "" do
    RepoConfig.find_path(get_in(config, ["repo_paths"]), repo) ||
      RepoConfig.find_path(Application.get_env(:wardmast, :repo_paths, %{}), repo)
  end

  defp primary_repo_path(_workspace, _repo), do: nil

  # The repo the task was actually worked in: its most recent run's.
  defp latest_run_repo(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [%Run{repo: repo} | _]} -> blank_to_nil(repo)
      _ -> nil
    end
  end

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil

  @typedoc """
  `status/2`'s read-only report: `behind` is how many commits `origin/<branch>`
  has that the LOCAL `<branch>` lacks; `blocker` is why `fast_forward/2` would
  leave it that way (`nil` when it is current, or when a sync would succeed).
  """
  @type status :: %{
          behind: non_neg_integer(),
          current_branch: String.t() | nil,
          blocker: skip_reason() | nil
        }

  @doc """
  How far the primary checkout's local `branch` has fallen behind
  `origin/<branch>`, and what would stop `fast_forward/2` from catching it up
  (bd-2rdfsh). Compares the LOCAL branch ref, not HEAD, because a bare
  `git log <branch>` is what a human or an old gate reads. Read-only, no fetch:
  the `origin/<branch>` it reads is as fresh as the last dispatch/sync fetch.
  """
  @spec status(path(), String.t()) :: {:ok, status()} | {:error, Worktree.error_reason()}
  def status(repo_path, branch) when is_binary(repo_path) and is_binary(branch) do
    with {:ok, out} <-
           run_git(
             ["rev-list", "--count", "refs/heads/#{branch}..refs/remotes/origin/#{branch}"],
             cd: repo_path
           ),
         {behind, _} <- Integer.parse(String.trim(out)),
         {:ok, current} <- Worktree.current_branch(repo_path) do
      {:ok,
       %{
         behind: behind,
         current_branch: current,
         blocker: blocker(repo_path, branch, behind, current)
       }}
    else
      :error -> {:error, {:git_failed, "unparseable rev-list output"}}
      {:error, _} = err -> err
    end
  end

  defp blocker(_repo_path, _branch, 0, _current), do: nil

  defp blocker(_repo_path, branch, _behind, current) when current != branch,
    do: :not_on_default_branch

  defp blocker(repo_path, branch, _behind, _current) do
    cond do
      Worktree.has_uncommitted?(repo_path) != {:ok, false} ->
        :uncommitted_changes

      match?(
        {:error, _},
        run_git(["merge-base", "--is-ancestor", "HEAD", "origin/" <> branch], cd: repo_path)
      ) ->
        :not_fast_forwardable

      true ->
        nil
    end
  end

  defp with_clean_tree(repo_path, base_branch) do
    case Worktree.has_uncommitted?(repo_path) do
      {:ok, true} -> {:skipped, :uncommitted_changes}
      {:ok, false} -> merge_ff_only(repo_path, base_branch)
      {:error, _} = err -> err
    end
  end

  defp merge_ff_only(repo_path, base_branch) do
    # Gate on ancestry explicitly rather than inferring "not fast-forwardable"
    # from any non-zero `merge --ff-only` exit: that command also fails on
    # index.lock contention (Dispatch runs `git worktree add` against this
    # same repo concurrently), a repo left mid-merge/mid-rebase by a human,
    # or `origin/<base>` failing to resolve — none of which are benign skips
    # (bd-bqqnin finding 4).
    case run_git(["merge-base", "--is-ancestor", "HEAD", "origin/" <> base_branch],
           cd: repo_path
         ) do
      {:ok, _output} ->
        case run_git(["merge", "--ff-only", "origin/" <> base_branch], cd: repo_path) do
          {:ok, _output} -> :ok
          {:error, _} = err -> err
        end

      {:error, {:git_failed, _msg}} ->
        {:skipped, :not_fast_forwardable}
    end
  end

  # `Worktree`'s own git-runner is private, so mirror it here rather than
  # exporting an internal helper across module boundaries.
  defp run_git(args, opts) do
    cd = Keyword.get(opts, :cd)

    if is_binary(cd) and not File.dir?(cd) do
      {:error, {:git_failed, "cwd does not exist: #{cd}"}}
    else
      case System.cmd("git", args, stderr_to_stdout: true, cd: cd) do
        {output, 0} -> {:ok, output}
        {output, _nonzero} -> {:error, {:git_failed, String.trim(output)}}
      end
    end
  rescue
    e in ErlangError -> {:error, {:git_failed, Exception.message(e)}}
  end
end
