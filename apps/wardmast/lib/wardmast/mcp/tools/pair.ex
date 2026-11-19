defmodule Wardmast.MCP.Tools.Pair do
  @moduledoc """
  The pair session's MCP tools (bd-7p6a9o): `pair_open`, `pair_done` and
  `pair_end` — the twins of `ward pair <ticket>`, `ward pair done <ticket>` and
  `ward pair end <ticket>` (`POST /api/issues/:id/pair`, `POST
  /api/issues/:id/pair/done`, `DELETE /api/issues/:id/pair`). Each is a thin
  door onto `Wardmast.Sessions.Pair`, which owns the rules.

  Opening and ending are coordinator calls. `pair_done` is also open to the
  pair session's own ticket-scoped token — the agent finishing the session it
  is in, at the operator's word — and to no other worker token: a worker-tier
  caller must carry the live pair session's id.
  """

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Sessions
  alias Wardmast.Sessions.Pair

  # How long a `pair_done` call waits on Done before answering that it is
  # still running: under a client's patience for one tool call, and over the
  # pre-push recipe's usual budget. Done carries on regardless.
  @done_wait_ms 240_000

  @not_your_session "only the coordinator, or the ticket's live pair session itself, may run Done " <>
                      "on a pair session"

  @doc "Open — or reopen — the ticket's pair session, and put it in the dock."
  @spec pair_open(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def pair_open(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      case Pair.open(issue) do
        {:ok, %{session: session, reopened?: reopened?}} ->
          _ = Sessions.request_open(session.id)
          {:ok, Map.put(Pair.summary(session), :reopened, reopened?)}

        {:error, reason} ->
          refusal(reason)
      end
    end
  end

  @doc "Run Done on the ticket's pair session (`Wardmast.Sessions.Pair.finish/2`)."
  @spec pair_done(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def pair_done(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- authorize_done(scope, issue.id) do
      case Pair.finish(issue, caller_session_id: scope.session_id, timeout: @done_wait_ms) do
        {:ok, result} -> {:ok, Pair.done_summary(issue.id, result)}
        {:error, reason} -> refusal(reason)
      end
    end
  end

  @doc "End the ticket's pair session without Done, leaving its worktree and branch."
  @spec pair_end(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def pair_end(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      case Pair.close(issue) do
        {:ok, ended} -> {:ok, Pair.summary(ended)}
        {:error, reason} -> refusal(reason)
      end
    end
  end

  # A worker-tier token may finish only the pair session it belongs to: the
  # pair session's own token carries that session's id (`Scope.mint_pair/4`); a
  # dispatched worker's carries none.
  defp authorize_done(%Scope{tier: :worker, session_id: sid}, issue_id) when is_binary(sid) do
    case Pair.live_session(issue_id) do
      {:ok, %{id: ^sid}} -> :ok
      _ -> {:error, {:unauthorized, @not_your_session}}
    end
  end

  defp authorize_done(%Scope{tier: :worker}, _issue_id),
    do: {:error, {:unauthorized, @not_your_session}}

  defp authorize_done(_scope, _issue_id), do: :ok

  defp refusal(reason), do: {:error, {kind(reason), Pair.describe_error(reason)}}

  defp kind(reason) when reason in [:issue_not_found, :no_pair_session], do: :not_found
  defp kind(_reason), do: :conflict
end
