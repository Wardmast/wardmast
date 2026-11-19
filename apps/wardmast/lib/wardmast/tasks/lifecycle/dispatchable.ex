defmodule Wardmast.Tasks.Lifecycle.Dispatchable do
  @moduledoc """
  The one dispatch-eligibility predicate (bd-9yqspm, child 3: bd-asxw4e).

  Before this module there were four answers to "may this ticket be
  dispatched?": the board's Ready filter, the scheduler's own card blocks,
  Autopilot's own re-check in `Wardmast.Worker.Dispatch`, and nothing at
  all for a manual dispatch, which went ahead from Backlog or past open
  blockers without a word. Now `Wardmast.Board.Scheduler.plan/1` and
  `Wardmast.Worker.Dispatch` both ask `dispatchable/2`.

  A ticket is dispatchable when

    1. its column (`Wardmast.Tasks.Lifecycle.view/2`) is `:ready` — `:queued`,
       with no unsatisfied gating blocker; and
    2. the scheduler holds nothing against it: a `:conflicts_with`
       counterpart in flight, a file overlap with in-flight work, a paused
       scheduler, a quota or auth hold, or no free slot.

  It is pure, like the view: every hold is an input in `ctx`, and a hold the
  caller does not pass is not asked about. So the scheduler passes all of
  them, and a manual dispatch — the operator overriding the scheduler —
  passes only the column's inputs.

  ## ctx

    * `:blocked_by`, `:runs`, `:held` — as for `Wardmast.Tasks.Lifecycle.view/2`;
    * `:conflicts_with` — the ticket's `:conflicts_with` counterparts, and
      `:claimed` — `%{id => label}` (or a list of ids) of what is in flight;
    * `:scope` — the ticket's declared file scope, and `:in_flight` —
      `[{task_id, changed_files, repo}]` for work already holding files, and `:repo` — the ticket's repo (holds only apply within one repo);
    * `:paused` — the scheduler is paused;
    * `:provider_constraint` — `:ok`, or `{:hold, detail}`: the ticket's own
      provider constraint (bd-13pqcp) leaves no eligible account with capacity;
    * `:guardrail` — `:ok`, or `{:hold, detail}`: no model the guardrail profiles
      allow can take the ticket, or a declared permission awaits the operator's
      grant (bd-atll60, G13);
    * `:local_capacity` — `:ok`, or `{:hold, phrase}`: the ticket's run can only go
      to the primary, and the primary's own cap has no room for it
      (`Wardmast.Nodes.LocalCapacity`'s phrase, bd-akp9ae);
    * `:ci_saturated` — `:ok`, or `{:hold, detail}`: the ticket's repo has too many
      MR pipelines waiting on a CI runner (`Wardmast.Board.CiBackpressure`, #1126);
    * `:pair_session` — `{:hold, session_id}` while a live pair session claims
      the ticket (`Wardmast.Sessions.Pair`, bd-7p6a9o); absent or `nil` otherwise.

  ## Holds, in precedence order

  The column first, then the ticket's own holds, then the board-wide ones —
  the same order the board has always shown reasons in, because a card's own
  block survives the board-wide one clearing.

  | hold | meaning |
  |---|---|
  | `{:column, :backlog}` | in Backlog — not promoted |
  | `{:blocked_by, ids}` | queued, waiting on these blockers |
  | `{:column, column}` | already past Ready (`:in_progress`, `:merging`, `:verifying`, `:closed`) |
  | `{:pair_session, session_id}` | a live pair session claims the ticket (bd-7p6a9o) |
  | `{:conflicts_with, id}` | a `:conflicts_with` counterpart is in flight |
  | `{:file_overlap, files, id, source}` | files `id` has changed (`source` is `:diff`) in the same repo that this ticket's text declares; text mentions on the in-flight side never count |
  | `{:provider_constraint, detail}` | the ticket's provider constraint leaves no eligible account |
  | `{:guardrail, detail}` | no model its guardrails allow can take it, or a permission awaits the operator's grant |
  | `{:local_capacity, phrase}` | it can only run on the primary, whose own cap is full |
  | `{:ci_saturated, detail}` | its repo's CI queue is saturated (`worker.repos.<repo>.ci_backpressure`) |
  | `:paused` | the scheduler is paused |
  """

  alias Wardmast.Board.FileScope
  alias Wardmast.Tasks.EdgeGate
  alias Wardmast.Tasks.Lifecycle.View

  @type hold ::
          {:column, View.column() | nil}
          | {:blocked_by, [String.t()]}
          | {:conflicts_with, String.t()}
          | {:file_overlap, [String.t()], String.t(), :diff}
          | {:provider_constraint, String.t()}
          | {:guardrail, String.t()}
          | {:local_capacity, String.t()}
          | {:ci_saturated, String.t()}
          | :paused
          | {:pair_session, String.t()}

  @type result :: :ok | {:held, hold()}

  @column_names %{
    backlog: "in Backlog",
    in_progress: "already In progress",
    merging: "already Merging",
    verifying: "already Verifying",
    closed: "Closed"
  }

  @doc "May `ticket` be dispatched, given `ctx`? See the moduledoc."
  @spec dispatchable(map(), map()) :: result()
  def dispatchable(ticket, ctx \\ %{}) when is_map(ticket) and is_map(ctx) do
    with :ok <- column_hold(View.view(ticket, Map.take(ctx, [:blocked_by, :runs, :held]))),
         :ok <- pair_session_hold(ctx),
         :ok <- mutex_hold(ctx),
         :ok <- overlap_hold(ctx),
         :ok <- provider_constraint_hold(ctx),
         :ok <- guardrail_hold(ctx),
         :ok <- local_capacity_hold(ctx),
         :ok <- ci_saturated_hold(ctx) do
      board_hold(ctx)
    end
  end

  @doc "`dispatchable/2 == :ok`."
  @spec dispatchable?(map(), map()) :: boolean()
  def dispatchable?(ticket, ctx \\ %{}), do: dispatchable(ticket, ctx) == :ok

  @doc ~s(The hold, phrased for an operator: `"in Backlog"`, `"blocked by bd-3, bd-9"`.)
  @spec describe_hold(hold()) :: String.t()
  def describe_hold({:column, column}), do: Map.get(@column_names, column, "not on the board")
  def describe_hold({:blocked_by, ids}), do: "blocked by " <> Enum.join(ids, ", ")
  def describe_hold({:conflicts_with, peer}), do: EdgeGate.describe({:conflicts_with, peer})

  def describe_hold({:file_overlap, files, task_id, source}),
    do: "#{name_files(files)} in flight on #{task_id} (#{source})"

  def describe_hold({:provider_constraint, detail}), do: "provider constraint (#{detail})"
  def describe_hold({:guardrail, detail}), do: "guardrail (#{detail})"
  def describe_hold({:local_capacity, phrase}), do: phrase
  def describe_hold({:ci_saturated, detail}), do: "CI saturated (#{detail})"
  def describe_hold(:paused), do: "scheduler paused"

  def describe_hold({:pair_session, session_id}),
    do: "claimed by a live pair session (#{String.slice(to_string(session_id), 0, 8)})"

  # ---- holds ----------------------------------------------------------------

  # bd-7p6a9o: a live pair session claims its ticket outright — an operator
  # and an agent are working in its worktree, and a worker beside them would
  # interleave commits on the same branch. The ticket's own hold, and the
  # strongest one: nothing the scheduler could free up (a slot, a quota
  # window, a counterpart merging) makes the ticket dispatchable while the
  # session lives. Ending the session is the only release.
  defp pair_session_hold(%{pair_session: {:hold, session_id}}),
    do: {:held, {:pair_session, session_id}}

  defp pair_session_hold(_ctx), do: :ok

  defp column_hold(%{column: :ready}), do: :ok
  # bd-abg443: a quota-held active ticket reads Blocked on the board but is
  # already In progress as far as dispatch goes — never fresh work.
  defp column_hold(%{column: :blocked, hold: %{}}), do: {:held, {:column, :in_progress}}
  defp column_hold(%{column: :blocked, blocked_by: ids}), do: {:held, {:blocked_by, ids}}
  defp column_hold(%{column: column}), do: {:held, {:column, column}}

  defp mutex_hold(ctx) do
    case EdgeGate.gate(%{
           conflicts: Map.get(ctx, :conflicts_with),
           claimed: Map.get(ctx, :claimed)
         }) do
      :ok -> :ok
      {:blocked, {:conflicts_with, peer}} -> {:held, {:conflicts_with, peer}}
    end
  end

  # Already-running work first, in the order given — so a collision is
  # attributed to the worker that has actually been holding the file.
  defp overlap_hold(ctx) do
    scope = scope_of(Map.get(ctx, :scope))
    repo = Map.get(ctx, :repo)

    ctx
    |> Map.get(:in_flight)
    |> List.wrap()
    |> Enum.find_value(:ok, fn entry ->
      {task_id, other, other_repo} = in_flight_parts(entry)

      with true <- other_repo == repo,
           [_ | _] = files <- FileScope.overlap(scope, scope_of(other)) do
        {:held, {:file_overlap, files, task_id, :diff}}
      else
        _ -> nil
      end
    end)
  end

  defp in_flight_parts({task_id, scope}), do: {task_id, scope, nil}
  defp in_flight_parts({task_id, scope, repo}), do: {task_id, scope, repo}

  # A ticket's own block, like a mutex: it survives the board-wide holds
  # clearing, and it does not hold the queue behind it.
  defp provider_constraint_hold(%{provider_constraint: {:hold, detail}}),
    do: {:held, {:provider_constraint, detail}}

  defp provider_constraint_hold(_ctx), do: :ok

  # bd-atll60 (G13): the same kind of block — the ticket's own, which survives the
  # board-wide holds clearing and does not hold the queue behind it. Waiting does
  # not fix it (a quota hold is the board's, not this one): no model its
  # guardrails allow exists for it, or an operator has yet to grant a permission.
  defp guardrail_hold(%{guardrail: {:hold, detail}}), do: {:held, {:guardrail, detail}}
  defp guardrail_hold(_ctx), do: :ok

  # bd-akp9ae: the ticket's own block too. Its workspace places runs on nodes, but
  # this run can only go to the primary, whose cap is full: the board-wide slot
  # count (which counts the nodes) is not what holds it, and the card behind it may
  # well fit on a node.
  defp local_capacity_hold(%{local_capacity: {:hold, phrase}}),
    do: {:held, {:local_capacity, phrase}}

  defp local_capacity_hold(_ctx), do: :ok

  # #1126: the ticket's repo is waiting on its CI runners. The card's own block, like
  # the above: it does not hold the queue behind it, whose repos may have room.
  defp ci_saturated_hold(%{ci_saturated: {:hold, detail}}), do: {:held, {:ci_saturated, detail}}
  defp ci_saturated_hold(_ctx), do: :ok

  defp board_hold(%{paused: true}), do: {:held, :paused}
  defp board_hold(_ctx), do: :ok

  defp scope_of(%MapSet{} = scope), do: scope
  defp scope_of(paths) when is_list(paths), do: MapSet.new(paths)
  defp scope_of(_), do: MapSet.new()

  defp name_files([file]), do: file
  defp name_files([file | rest]), do: "#{file} +#{length(rest)} more"
end
