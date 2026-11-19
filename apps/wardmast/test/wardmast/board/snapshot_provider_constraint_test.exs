defmodule Wardmast.Board.SnapshotProviderConstraintTest do
  @moduledoc """
  bd-13pqcp: a Ready ticket whose provider constraint leaves no eligible
  account with capacity is held on the board with `held — provider constraint
  (<detail>)`, as its own block (it does not hold the queue behind it), so
  Autopilot plans past it. A ticket without a constraint, or with an eligible
  provider, is planned exactly as before.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Board.Snapshot
  alias Wardmast.Tasks.Workspace

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "spc-#{n}", prefix: "spc#{n}", config: config})
  end

  defp failover!(types \\ ["claude", "gemini"]),
    do: workspace!(%{"agent" => %{"type" => types}})

  defp issue(id, ws, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: ws.id,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: now,
        updated_at: now,
        closed_at: nil
      },
      extra
    )
  end

  defp load_ready(ws, issues) do
    board = Snapshot.load(workspace_id: ws.id, issues: issues, workers: [], slots_total: 3)
    Map.new(board.ready, &{&1.card.id, &1})
  end

  test "an unconstrained ticket is planned as before" do
    ws = failover!()
    assert %{"t-1" => %{state: :next}} = load_ready(ws, [issue("t-1", ws)])
  end

  test "a constraint that leaves an eligible provider does not hold the card" do
    ws = failover!()
    constrained = issue("t-1", ws, %{provider_constraint: %{"exclude" => ["gemini"]}})

    assert %{"t-1" => %{state: :next}} = load_ready(ws, [constrained])
  end

  test "a constraint that leaves no provider in the pool holds the card, and the next one goes" do
    ws = failover!(["claude", "gemini"])
    stuck = issue("t-1", ws, %{provider_constraint: %{"exclude" => ["claude", "gemini"]}})

    ready = load_ready(ws, [stuck, issue("t-2", ws)])

    assert %{state: :blocked, reason: reason} = ready["t-1"]
    assert reason =~ "held — provider constraint (exclude claude, gemini"
    assert %{state: :next} = ready["t-2"]
  end
end
