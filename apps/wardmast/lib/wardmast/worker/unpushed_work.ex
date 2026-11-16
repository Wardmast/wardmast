defmodule Wardmast.Worker.UnpushedWork do
  @moduledoc """
  Commits a task's preserved local worktree holds that no remote has (bd-ap53dg).

  A run that stays red at the pre-push gate, a failed push or a crash before the push
  leaves its commits only in the worktree. `arb worker show` lists them so the operator
  sees that fact before resuming, and `Wardmast.Worker.Dispatch` keeps such a task's
  next run on the primary (`Wardmast.Nodes.Placement`'s `:unpushed_commits`).
  """

  alias Wardmast.Tasks.Issue
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.Worktree

  @list_limit 20

  @doc """
  `%{path, count, commits}` for the ticket's preserved worktree, or `nil` when there is
  no worktree, nothing unpushed, or git cannot read it. `commits` is capped (newest
  first), so `count` may exceed its length.
  """
  @spec for_task(String.t() | nil) ::
          %{
            path: String.t(),
            count: pos_integer(),
            commits: [%{sha: String.t(), subject: String.t()}]
          }
          | nil
  def for_task(ticket_id) when is_binary(ticket_id) do
    with {:ok, %Issue{} = task} <- Ash.get(Issue, ticket_id),
         path = task |> BranchNamer.derive() |> Worktree.worktree_path(),
         true <- File.dir?(path),
         {:ok, count} when count > 0 <- Worktree.unpushed_commits(path),
         {:ok, commits} <- Worktree.unpushed_commit_list(path, @list_limit) do
      %{path: path, count: count, commits: commits}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def for_task(_ticket_id), do: nil
end
