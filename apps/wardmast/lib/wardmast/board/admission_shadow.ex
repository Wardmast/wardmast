defmodule Wardmast.Board.AdmissionShadow do
  @moduledoc """
  What the admission walk records beside today's plan (DC6, bd-9ycsk4;
  `docs/design/provider-dynamic-concurrency.md` §10.1-§10.2). Since DC12 the walk
  is the only admission: its placement goes, its pair riding into dispatch as
  `planned/1`, and today's decision is recorded beside it (the reverse shadow).

  ## What is recorded

    * **Beside every dispatch** — `reverse_record/2`, stored on the run as
      `routing_decision.admission_shadow`: `pick` is today's plan's card, `agrees`
      whether it is the card dispatched, `comparable` whether both sides had a
      candidate, and `cause` why today would not have dispatched the walk's
      (`queued`, `legacy_hold`); the (pool, machine) pair is the walk's.
    * **On every hold change** — `signature/1` is what a pass decided on each
      side: today's pick or the head it holds and why, the walk's first
      placement or the head it skips and why, and the pools whose budget sits
      below today's cap. Autopilot writes one `Wardmast.Board.AdmissionShadowEvent`
      (`event/2`, `record_event/1`) when the signature changes, so a steady
      board writes nothing however often it is planned.

  Everything else here is a record: only `planned/1` reaches a dispatch.
  """

  require Logger

  alias Wardmast.Board.AdmissionShadowEvent

  @board_holds [:no_slot, :quota, :paused]

  # ---- the walk decides (DC8) ------------------------------------------------

  @doc """
  The pair a walk placement rides into dispatch as, `opts[:planned]` (design
  §4.4): its account, pool and machine. A pool with no account behind it (an
  unmetered provider) plans the machine only.
  """
  @spec planned(map()) :: %{account_id: String.t() | nil, pool: String.t() | nil, node: term()}
  def planned(%{pool: {account_id, pool}, node: node}) when is_binary(account_id),
    do: %{account_id: account_id, pool: pool, node: node}

  def planned(%{node: node}), do: %{account_id: nil, pool: nil, node: node}

  @doc """
  The **reverse shadow** (§10.1-§10.2): under `enforce` the walk dispatched
  `placement`, and this records beside it what today's plan would have done —
  `pick` is today's `promote`, `agrees` whether that is the card dispatched, and
  the pass is `comparable` when today had a candidate too. `cause` says why
  today would not have dispatched ours: `queued` (it would have dispatched
  another card first) or `legacy_hold` (it held ours, or held the queue at its
  head; `legacy_hold` names the hold). The pair and the placement count are the
  walk's. String keys: it is stored as-is.
  """
  @spec reverse_record(map(), map()) :: map()
  def reverse_record(%{walk: %{} = walk} = board, %{id: dispatched} = placement) do
    pick = Map.get(board, :promote)
    ours = board |> Map.get(:ready, []) |> Enum.find(&(&1.id == dispatched))
    {cause, hold} = reverse_cause(board, pick, dispatched, ours)

    walk
    |> placement_fields(placement)
    |> Map.merge(%{
      "policy" => "enforce",
      "dispatched" => dispatched,
      "pick" => pick,
      "agrees" => pick == dispatched,
      "comparable" => not is_nil(pick),
      "cause" => cause,
      "legacy_hold" => hold,
      "reason" => if(pick == dispatched, do: nil, else: ours && ours.reason),
      "placements" => length(walk.placements)
    })
  end

  defp reverse_cause(_board, pick, pick, _ours), do: {nil, nil}
  defp reverse_cause(_board, _pick, _dispatched, nil), do: {"not_planned", nil}

  defp reverse_cause(_board, _pick, _dispatched, %{state: :blocked, hold: hold}),
    do: {"legacy_hold", kind_text(hold_kind(hold))}

  defp reverse_cause(board, nil, _dispatched, _ours) do
    head = legacy_head(board)
    {"legacy_hold", head && kind_text(hold_kind(head.hold))}
  end

  defp reverse_cause(_board, _pick, _dispatched, _ours), do: {"queued", nil}

  # ---- on a hold change --------------------------------------------------------

  @doc """
  What a board's pass decided, on both sides, without the words: today's pick
  or the head it holds and its hold, the walk's first placement or the head it
  skips and its wait cause, and the pools whose budget is below today's cap.
  Two passes with the same signature are the same admission outcome.
  """
  @spec signature(map()) :: term()
  def signature(board) do
    walk = Map.get(board, :walk) || %{}
    {legacy_outcome(board), walk_outcome(walk), below_cap(walk)}
  end

  @doc "The `AdmissionShadowEvent` attributes for `board`'s pass at `at`."
  @spec event(map(), DateTime.t()) :: map()
  def event(board, %DateTime{} = at) do
    walk = Map.get(board, :walk) || %{promote: nil, placements: [], entries: [], pools: %{}}
    legacy_pick = Map.get(board, :promote)
    walk_pick = walk.promote

    %{
      at: at,
      policy: "enforce",
      legacy_pick: legacy_pick,
      walk_pick: walk_pick,
      agrees: legacy_pick == walk_pick,
      comparable: not is_nil(legacy_pick) and not is_nil(walk_pick),
      cause: event_cause(walk, legacy_pick, walk_pick),
      legacy: legacy_side(board),
      walk: walk_side(walk),
      budgets: budgets(Map.get(walk, :pools) || %{})
    }
  end

  @doc "Write one event row. A row that cannot be written is logged and dropped."
  @spec record_event(map()) :: :ok
  def record_event(attrs) do
    case Ash.create(AdmissionShadowEvent, attrs, action: :record) do
      {:ok, _row} -> :ok
      {:error, error} -> drop(error)
    end
  rescue
    e -> drop(e)
  catch
    :exit, reason -> drop(reason)
  end

  defp drop(error) do
    Logger.warning("AdmissionShadow: an event row was not written: #{inspect(error, limit: 5)}")
    :ok
  end

  # ---- the two sides -----------------------------------------------------------

  defp legacy_outcome(board) do
    case Map.get(board, :promote) do
      id when is_binary(id) ->
        {:place, id}

      nil ->
        case legacy_head(board) do
          nil -> :empty
          entry -> {:hold, entry.id, hold_kind(entry.hold)}
        end
    end
  end

  defp walk_outcome(walk) do
    case Map.get(walk, :placements) || [] do
      [first | _] ->
        {:place, first.id, first.pool, first.node}

      [] ->
        case walk_head(walk) do
          nil -> :empty
          entry -> {:hold, entry.id, entry.wait_cause}
        end
    end
  end

  defp below_cap(walk) do
    for {id, pool} <- Map.get(walk, :pools) || %{},
        is_integer(Map.get(pool, :cap)) and is_integer(pool.budget) and pool.budget < pool.cap,
        do: id,
        into: MapSet.new()
  end

  # Today's head when it holds: the card a board-wide hold stopped, else the
  # first card held on its own.
  defp legacy_head(board) do
    blocked = board |> Map.get(:ready, []) |> Enum.filter(&(&1.state == :blocked))
    Enum.find(blocked, &(hold_kind(&1.hold) in @board_holds)) || List.first(blocked)
  end

  # The walk's head when it places nothing: the first card waiting on a layer
  # or behind work, else the first card held on its own.
  defp walk_head(walk) do
    entries = Map.get(walk, :entries) || []
    Enum.find(entries, &(&1.wait_cause not in [nil, :own_hold])) || List.first(entries)
  end

  defp legacy_side(board) do
    case Map.get(board, :promote) do
      id when is_binary(id) ->
        %{"pick" => id, "head" => id, "hold" => nil, "reason" => entry_reason(board.ready, id)}

      nil ->
        head = legacy_head(board)

        %{
          "pick" => nil,
          "head" => head && head.id,
          "hold" => head && kind_text(hold_kind(head.hold)),
          "reason" => head && head.reason
        }
    end
  end

  defp walk_side(walk) do
    head = if walk.promote, do: nil, else: walk_head(walk)

    walk
    |> pick_fields()
    |> Map.merge(%{
      "pick" => walk.promote,
      "placements" => Enum.map(walk.placements, & &1.id),
      "head" => head && head.id,
      "wait_cause" => head && cause_text(head.wait_cause),
      "reason" => head && head.reason
    })
  end

  defp pick_fields(%{placements: [first | _]} = walk), do: placement_fields(walk, first)

  defp pick_fields(_walk),
    do: %{"account_id" => nil, "pool" => nil, "pool_label" => nil, "node" => nil}

  defp placement_fields(walk, placement) do
    {account_id, pool} = pool_parts(placement.pool)

    %{
      "account_id" => account_id,
      "pool" => pool,
      "pool_label" => get_in(walk, [:pools, placement.pool, :label]),
      "node" => placement.node
    }
  end

  defp budgets(pools) do
    pools
    |> Enum.map(fn {id, pool} ->
      {account_id, name} = pool_parts(id)

      %{
        "account_id" => account_id,
        "pool" => name,
        "label" => Map.get(pool, :label),
        "budget" => json_count(pool.budget),
        "seats" => pool.seats,
        "free" => free(pool),
        "exempt_budget" => Map.get(pool, :exempt_budget),
        "cap" => Map.get(pool, :cap),
        "binding" => binding_text(Map.get(pool, :binding)),
        "reason" => Map.get(pool, :reason)
      }
    end)
    |> Enum.sort_by(&{&1["label"] || "", &1["pool"] || ""})
  end

  # ---- causes ------------------------------------------------------------------

  # Why the walk would not have dispatched `id` first: placed too, but after a
  # card today holds (`legacy_hold`); else its own wait cause.
  defp cause(%{promote: id}, id), do: nil

  defp cause(walk, id) do
    case Enum.find(walk.entries, &(&1.id == id)) do
      %{state: state} when state in [:next, :starting] -> "legacy_hold"
      %{wait_cause: wait_cause} -> cause_text(wait_cause)
      nil -> "not_planned"
    end
  end

  defp event_cause(_walk, pick, pick), do: nil
  defp event_cause(_walk, nil, _walk_pick), do: "legacy_hold"
  defp event_cause(walk, legacy_pick, _walk_pick), do: cause(walk, legacy_pick)

  defp entry_reason(ready, id) do
    case Enum.find(ready || [], &(&1.id == id)) do
      %{reason: reason} -> reason
      nil -> nil
    end
  end

  # ---- words -------------------------------------------------------------------

  defp hold_kind(nil), do: nil
  defp hold_kind({kind, _}), do: kind
  defp hold_kind({kind, _, _}), do: kind
  defp hold_kind(kind) when is_atom(kind), do: kind

  defp kind_text(nil), do: nil
  defp kind_text(kind), do: to_string(kind)

  defp cause_text(nil), do: nil
  defp cause_text({:capacity, layer}), do: "capacity:#{layer}"
  defp cause_text(cause) when is_atom(cause), do: to_string(cause)

  defp binding_text(nil), do: nil
  defp binding_text({:window, label}), do: "window:#{label}"
  defp binding_text(binding) when is_atom(binding), do: to_string(binding)
  defp binding_text(binding), do: inspect(binding)

  defp pool_parts({:unmetered, provider}), do: {nil, to_string(provider)}
  defp pool_parts({account_id, pool}), do: {account_id, pool}
  defp pool_parts(other), do: {nil, inspect(other)}

  defp free(%{budget: :unlimited}), do: "unlimited"
  defp free(%{budget: budget, seats: seats}), do: max(budget - seats, 0)

  defp json_count(:unlimited), do: "unlimited"
  defp json_count(n), do: n
end
