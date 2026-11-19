defmodule Wardmast.Workflows.PRPatrol.AuthorScope do
  @moduledoc """
  Whose PRs/MRs PRPatrol may act on, and whether a follow-up worker may PUSH to
  one (bd-cwigjh / #1550).

  Once GitLab's patrol triggers went live (bd-c1htb2) an unset
  `pr_patrol.author_logins` — which used to mean "every open PR" — made PRPatrol
  file follow-ups against every MR in the project. Those follow-ups merge the
  target branch into the MR and push it under the operator's identity, which on a
  colleague's branch is an unrequested push. The scope is therefore resolved by
  `Wardmast.Tasks.Workspace.pr_patrol_author_scope/1`:

    * `:own` (the default, `author_logins` unset) — only PRs Wardmast opened;
    * `{:logins, logins}` — only PRs authored by one of `logins`;
    * `:all` — `author_logins: "*"`, the explicit opt-in to everyone's PRs.

  ## Wardmast's own PRs (`:own`)

  A PR is Wardmast's when either

    * an `Issue` in the workspace carries its ref as `pr_ref` (the MergeQueue
      stamped it when it opened the PR), or
    * its author is the configured fleet login (`pr_patrol.our_login`, falling
      back to `review_patrol.our_login`).

  ## The push guard

  `push_decision/3` is the second line: it decides for one follow-up task whether
  its worker may push to the PR's branch, whoever filed it (PRPatrol or a human).
  The answer is `:ok` only when the PR's author is in scope; otherwise
  `{:refused, reason}`, and the dispatcher runs the worker comment-only — no push
  credential, a prompt that says so — and records the reason. It fails closed: an
  author that cannot be resolved is out of scope.
  """

  alias Wardmast.Mergers
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Workflows.{PatrolRepoScope, PatrolServer, PRPatrolSupervisor}

  require Ash.Query

  @doc """
  The `pr_ref`s of the workspace's tickets — the PRs/MRs Wardmast opened. A pure
  DB read of one column, run once per patrol tick.
  """
  @spec own_refs(String.t()) :: [String.t()]
  def own_refs(workspace_id) when is_binary(workspace_id) do
    Issue
    |> Ash.Query.filter(workspace_id == ^workspace_id and not is_nil(pr_ref))
    |> Ash.Query.select([:pr_ref])
    |> Ash.read!()
    |> Enum.map(& &1.pr_ref)
  rescue
    # Fail closed: no known refs means nothing is vouched for by a ticket.
    _ -> []
  end

  @doc """
  Whether `mr` (a `list_open/0` row, or any map with `:number` and `:author`) is
  in the workspace's scope. `own_refs` is `own_refs/1`'s result and `repo` the
  forge slug the patrol runs against; both only matter for `:own`.
  """
  @spec in_scope?(map(), Workspace.t(), [String.t()], String.t() | nil) :: boolean()
  def in_scope?(mr, %Workspace{} = workspace, own_refs, repo) do
    case Workspace.pr_patrol_author_scope(workspace) do
      :all -> true
      {:logins, logins} -> author(mr) in logins
      :own -> fleet_author?(mr, workspace) or ticket_linked?(mr, own_refs, repo)
    end
  end

  def in_scope?(_mr, _workspace, _own_refs, _repo), do: false

  @doc """
  May the worker of follow-up `task` push to the PR it was filed against?

  `:ok` when the workspace's scope is `:all` or the PR's author is in scope;
  `{:refused, reason}` otherwise, including when the author cannot be read. A task
  that is not a follow-up on an existing PR (no `source_pr`, or a review
  engagement) is not this guard's business and is `:ok`.
  """
  @spec push_decision(Issue.t(), Workspace.t() | nil, String.t() | nil) ::
          :ok | {:refused, String.t()}
  def push_decision(%Issue{review_only: true}, _workspace, _repo), do: :ok

  def push_decision(%Issue{source_pr: ref} = task, %Workspace{} = workspace, repo)
      when is_binary(ref) and ref != "" do
    case Workspace.pr_patrol_author_scope(workspace) do
      :all ->
        :ok

      _scoped ->
        decide(task, workspace, repo, ref)
    end
  end

  def push_decision(_task, _workspace, _repo), do: :ok

  defp decide(task, workspace, repo, ref) do
    case fetch_author(workspace, repo, ref) do
      {:ok, author} ->
        mr = %{ref: ref, number: ref_number(ref), author: author}

        if in_scope?(mr, workspace, own_refs(task.workspace_id), repo) do
          :ok
        else
          {:refused, refusal(ref, author, workspace)}
        end

      {:error, why} ->
        {:refused,
         "the author of #{ref} could not be resolved (#{why}), so it cannot be shown to be " <>
           "in pr_patrol.author_logins scope; failing closed"}
    end
  end

  defp refusal(ref, author, workspace) do
    scope =
      case Workspace.pr_patrol_author_scope(workspace) do
        {:logins, logins} -> "pr_patrol.author_logins (#{Enum.join(logins, ", ")})"
        _ -> "Wardmast's own PRs (no linked ticket, not authored by pr_patrol.our_login)"
      end

    "#{ref} is authored by #{author}, outside #{scope}; " <>
      "set pr_patrol.author_logins to \"*\" to allow pushes to other authors' branches"
  end

  # The PR's author, read through the repo's merge adapter. Any failure is an
  # error rather than a guess.
  defp fetch_author(workspace, repo, ref) do
    merge_ws = PRPatrolSupervisor.scope(workspace, repo)

    with adapter when not is_nil(adapter) <- PatrolServer.resolve_adapter(merge_ws),
         true <- function_exported?(adapter, :get, 1),
         :ok <- Mergers.prepare_with_repo(merge_ws, repo),
         {:ok, %{author: author}} when is_binary(author) and author != "" <- adapter.get(ref) do
      {:ok, author}
    else
      {:ok, _no_author} -> {:error, "the forge reported no author"}
      {:error, reason} -> {:error, inspect(reason)}
      _ -> {:error, "no forge adapter for this workspace"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp author(mr), do: Map.get(mr, :author)

  defp fleet_author?(mr, workspace) do
    case {Workspace.pr_patrol_our_login(workspace), author(mr)} do
      {login, login} when is_binary(login) and login != "" -> true
      _ -> false
    end
  end

  # A ticket's `pr_ref` vouches for the PR with the same number in the same repo.
  # `ref_matches_repo?/2` lets a bare ref (`#N` / `!N`) match the patrol's repo —
  # it can only exist in a single-repo workspace — and pins a qualified one.
  defp ticket_linked?(mr, own_refs, repo) do
    number = Map.get(mr, :number)

    is_integer(number) and
      Enum.any?(own_refs, fn ref ->
        ref_number(ref) == number and
          (is_nil(repo) or PatrolRepoScope.ref_matches_repo?(ref, repo))
      end)
  end

  defp ref_number(ref) when is_binary(ref) do
    case Regex.run(~r/(\d+)\s*$/, ref) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp ref_number(_ref), do: nil
end
