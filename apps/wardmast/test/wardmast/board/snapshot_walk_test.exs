defmodule Wardmast.Board.SnapshotWalkTest do
  @moduledoc """
  `Snapshot.derive/1` (DC6, provider-dynamic-concurrency §4; the only plan since
  DC12): the board carries the scheduler walk at `:walk`, and its entries are the
  Ready column. Without a `:walk`, or with one that cannot be planned, nothing is
  placed and every free card waits for capacity.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wardmast.Board.Snapshot

  @now ~U[2026-10-10 12:00:00Z]
  @claude {"acct-claude", "claude"}
  @gpt {"acct-agy", "antigravity:claude_and_gpt_models"}

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      attrs
    )
  end

  defp input(overrides) do
    Map.merge(
      %{
        issues: [],
        workers: [],
        blocked_by: %{},
        changed_files: %{},
        now: @now,
        slots_total: 4,
        paused: false
      },
      Map.new(overrides)
    )
  end

  defp walk(candidates, pools \\ nil) do
    %{
      pools: pools || %{@claude => %{budget: 3, seats: 3}, @gpt => %{budget: 2, seats: 0}},
      nodes: %{"local" => %{cap: 6, used: 3}},
      candidates: candidates
    }
  end

  test "without :walk nothing is placed and every free card waits for capacity" do
    board = Snapshot.derive(input(issues: [issue("bd-1")]))

    assert %{promote: nil, placements: []} = board.walk

    assert [%{id: "bd-1", state: :blocked, reason: "waiting for capacity — " <> _}] =
             board.ready
  end

  test "the walk's entries are the Ready column" do
    issues = [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 2})]

    # bd-a can only use the full claude pool; bd-b can use agy's free one.
    candidates = %{
      "bd-a" => [%{pool: @claude, nodes: ["local"]}],
      "bd-b" => [%{pool: @claude, nodes: ["local"]}, %{pool: @gpt, nodes: ["local"]}]
    }

    board = Snapshot.derive(input(issues: issues, walk: walk(candidates)))

    assert Enum.map(board.ready, & &1.id) == Enum.map(board.walk.entries, & &1.id)

    assert %{promote: "bd-b", placements: [%{id: "bd-b", pool: @gpt, node: "local"}]} =
             board.walk

    assert %{wait_cause: {:capacity, :provider}} = Enum.find(board.ready, &(&1.id == "bd-a"))

    # The capacity sets the walk ran against ride with it.
    assert board.walk.pools == walk(candidates).pools
    assert board.walk.nodes == walk(candidates).nodes
  end

  test "the walk holds on the 15 s retry window" do
    issues = [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 2})]
    everywhere = fn _card -> [%{pool: @gpt, nodes: ["local"]}] end

    board =
      Snapshot.derive(
        input(
          issues: issues,
          # bd-814vuy's 15 s hold after a refused dispatch: the card's own.
          dispatch_holds: %{"bd-b" => {:hold, "dispatch refused (account at capacity)"}},
          walk: walk(everywhere)
        )
      )

    assert board.walk.promote == "bd-a"
    assert %{wait_cause: :own_hold} = Enum.find(board.walk.entries, &(&1.id == "bd-b"))
  end

  # Seen live (v0.2.43): the machines' caps summed (local 2 + node 3), and five
  # tickets In progress fill it — four on the primary (two implementers and two
  # review-side runs its cap never holds), one on the node. The walk counts each
  # machine against its own cap and places the Ready card on the node's free slot.
  test "a node's free slot is placeable while the primary is over its own cap" do
    issues = Enum.map(1..5, &issue("bd-run-#{&1}", %{state: :active})) ++ [issue("bd-ready")]

    walk = %{
      pools: %{@claude => %{budget: 9, seats: 5, label: "claude:default"}},
      nodes: %{
        "local" => %{cap: 2, used: 4, label: "local"},
        "oryx" => %{cap: 3, used: 1, label: "ryan-oryx-pro"}
      },
      candidates: fn _card -> [%{pool: @claude, nodes: [["oryx"], ["local"]]}] end
    }

    board = Snapshot.derive(input(issues: issues, slots_total: 5, walk: walk))

    assert %{promote: "bd-ready", placements: [%{id: "bd-ready", pool: @claude, node: "oryx"}]} =
             board.walk
  end

  @tag capture_log: true
  test "a walk that cannot be planned is planned with no capacity: the board still renders" do
    issues = [issue("bd-a")]

    broken = [
      # A candidates function that raises.
      walk(fn _ -> raise "boom" end),
      # Something that is not a walk at all.
      %{pools: :nope, nodes: :nope, candidates: :nope}
    ]

    for walk <- broken do
      board = Snapshot.derive(input(issues: issues, walk: walk))

      assert %{promote: nil, placements: []} = board.walk
      assert [%{id: "bd-a", state: :blocked}] = board.ready
      assert Enum.map(board.backlog ++ board.in_progress, & &1.id) == []
    end
  end

  # ---- the walk's entries are the Ready column ------------------------------------

  defp issue_gen(id) do
    gen all(
          state <- member_of([:queued, :queued, :queued, :active, :merging, :backlog]),
          priority <- integer(0..4),
          ws <- member_of(["ws-1", "ws-2"])
        ) do
      issue(id, %{state: state, priority: priority, workspace_id: ws})
    end
  end

  defp capacity_gen(ids) do
    gen all(
          claude <- fixed_map(%{budget: integer(0..3), seats: integer(0..3)}),
          gpt <- fixed_map(%{budget: integer(0..3), seats: integer(0..3)}),
          local <- fixed_map(%{cap: integer(0..4), used: integer(0..4)}),
          picks <-
            fixed_list(
              Enum.map(ids, fn _ -> member_of([[@claude], [@gpt], [@claude, @gpt], []]) end)
            )
        ) do
      candidates =
        ids
        |> Enum.zip(picks)
        |> Map.new(fn {id, pools} -> {id, Enum.map(pools, &%{pool: &1, nodes: ["local"]})} end)

      %{
        pools: %{@claude => claude, @gpt => gpt},
        nodes: %{"local" => local},
        candidates: candidates
      }
    end
  end

  property "whatever the capacity, Ready is the walk's entries and a placement is a Ready card" do
    ids = Enum.map(1..6, &"bd-#{&1}")

    check all(
            issues <- fixed_list(Enum.map(ids, &issue_gen/1)),
            paused <- member_of([false, false, false, true]),
            capacity <- capacity_gen(ids),
            max_runs: 200
          ) do
      board = Snapshot.derive(input(issues: issues, paused: paused, walk: capacity))

      assert Enum.map(board.ready, & &1.id) == Enum.map(board.walk.entries, & &1.id)
      assert Enum.all?(board.walk.placements, &(&1.id in Enum.map(board.ready, fn e -> e.id end)))
      if paused, do: assert(board.walk.placements == [])
    end
  end
end
