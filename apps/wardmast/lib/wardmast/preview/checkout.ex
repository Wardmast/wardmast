defmodule Wardmast.Preview.Checkout do
  @moduledoc """
  Picks the directory a ticket's app preview runs in — and never touches a
  worker's checkout to do it.

  | kind | when | what runs |
  |---|---|---|
  | `"worktree"` | the ticket's checkout is on the primary and no worker is live in it | the checkout itself |
  | `"snapshot"` | a worker is live in the ticket's checkout | a clone of its `HEAD` under the preview dir (uncommitted edits are not in it) |
  | `"remote_head"` | the ticket's run was placed on a cluster/machine node, so its checkout is not here | a clone of the branch's **pushed** head, fetched from `origin` on the primary |

  A preview checkout is built with `git clone --local --no-checkout` from the
  source and a detached `git checkout` of the chosen commit, so the source is
  only ever *read*; its `origin` remote is then removed, so a preview checkout
  has no push path ("read-only"). It lives at `<preview dir>/checkout` and is
  rebuilt on every start.
  """

  alias Wardmast.Tasks.Issue
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.Registry, as: WorkerRegistry
  alias Wardmast.Worker.Worktree
  alias Wardmast.Workers.Runs

  @type result :: %{path: String.t(), kind: String.t(), note: String.t() | nil}

  @doc """
  The checkout to preview `issue` from. `repo_path` is the primary's clone of
  the repo, `preview_dir` the preview's own directory.
  """
  @spec prepare(Issue.t(), String.t() | nil, String.t()) :: {:ok, result()} | {:error, term()}
  def prepare(%Issue{} = issue, repo_path, preview_dir) do
    branch = BranchNamer.derive(issue)
    worktree = Worktree.worktree_path(branch)
    local? = File.dir?(worktree)

    cond do
      remote_run?(issue.id) ->
        from_origin(repo_path, branch, preview_dir, "the ticket's checkout is on a cluster node")

      local? and worker_live?(issue.id) ->
        snapshot(worktree, branch, preview_dir)

      local? ->
        {:ok, %{path: worktree, kind: "worktree", note: nil}}

      true ->
        from_origin(repo_path, branch, preview_dir, "the ticket has no checkout on this machine")
    end
  end

  defp remote_run?(task_id) do
    case Runs.latest(task_id) do
      %{node_id: node_id} when not is_nil(node_id) -> true
      _ -> false
    end
  end

  defp worker_live?(task_id), do: WorkerRegistry.live_for(task_id) != []

  defp snapshot(worktree, branch, preview_dir) do
    with {:ok, sha} <- git(worktree, ["rev-parse", "HEAD"]),
         {:ok, dest} <- materialise(worktree, sha, preview_dir) do
      {:ok,
       %{
         path: dest,
         kind: "snapshot",
         note:
           "A worker is live in the ticket's checkout, so this runs a separate checkout of " <>
             "#{branch} at #{short(sha)}; uncommitted edits are not included."
       }}
    end
  end

  defp from_origin(nil, _branch, _preview_dir, _why), do: {:error, :no_repo_path}

  defp from_origin(repo_path, branch, preview_dir, why) do
    refspec = "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"

    with {:ok, _} <- git(repo_path, ["fetch", "--quiet", "origin", refspec]),
         {:ok, sha} <- git(repo_path, ["rev-parse", "--verify", "refs/remotes/origin/#{branch}"]),
         {:ok, dest} <- materialise(repo_path, sha, preview_dir) do
      {:ok,
       %{
         path: dest,
         kind: "remote_head",
         note:
           "Read-only preview checkout of #{branch} at its pushed head #{short(sha)}, " <>
             "built on the primary (#{why})."
       }}
    else
      {:error, {:git, _msg}} -> {:error, {:no_checkout, branch}}
    end
  end

  defp materialise(source, sha, preview_dir) do
    dest = Path.join(preview_dir, "checkout")
    File.rm_rf!(dest)
    _ = File.rm(Path.join(preview_dir, "setup.done"))
    File.mkdir_p!(preview_dir)

    with {:ok, _} <-
           git(preview_dir, ["clone", "--quiet", "--no-checkout", "--local", source, dest]),
         {:ok, _} <- git(dest, ["cat-file", "-e", sha <> "^{commit}"]),
         {:ok, _} <- git(dest, ["checkout", "--quiet", "--detach", sha]),
         _ <- git(dest, ["remote", "remove", "origin"]) do
      {:ok, dest}
    end
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, {:git, String.trim(out)}}
    end
  end

  defp short(sha), do: String.slice(sha, 0, 8)
end
