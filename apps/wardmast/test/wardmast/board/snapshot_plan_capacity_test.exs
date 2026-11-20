defmodule Wardmast.Board.SnapshotPlanCapacityTest do
  @moduledoc """
  DC12b: the board has no stored `slots_total`. Its one capacity number is the
  plan-time `min(Σ budget over the pools a Ready card can use, Σ machine caps)`,
  computed from the walk's pools and nodes, and both readers (the ES lift cap
  and the header/`CapacityExplainer`) take it.
  """
  use ExUnit.Case, async: true

  alias Wardmast.Board.CapacityExplainer
  alias Wardmast.Board.Snapshot

  @now ~U[2026-10-02 12:00:00Z]
  @a {"acct-a", "claude"}
  @b {"acct-b", "codex"}
  @c {"acct-c", "claude"}

  defp ready(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: id,
        state: :queued,
        priority: 2,
        rank: 1024,
        difficulty: 2,
        issue_type: :task,
        created_at: @now,
        updated_at: @now
      },
      attrs
    )
  end

  defp walk(pools, machines, candidates) do
    %{
      pools: Map.new(pools, fn {id, budget} -> {id, %{budget: budget, seats: 0}} end),
      nodes: Map.new(machines, fn {id, cap} -> {id, %{cap: cap, used: 0}} end),
      candidates: candidates
    }
  end

  defp derive(input), do: Snapshot.derive(Map.merge(%{now: @now}, input))

  test "no stored slots_total on the board" do
    board = derive(%{walk: walk(%{@a => 2}, %{"local" => 2}, %{})})
    refute Map.has_key?(board, :slots_total)
    assert board.plan_capacity == 2
  end

  test "sums the budget of only the pools a Ready card can use" do
    walk =
      walk(%{@a => 2, @b => 3, @c => 100}, %{"local" => 50}, %{
        "bd-1" => [%{pool: @a, nodes: ["local"]}],
        "bd-2" => [%{pool: @b, nodes: ["local"]}, %{pool: @a, nodes: ["local"]}]
      })

    board = derive(%{issues: [ready("bd-1"), ready("bd-2")], walk: walk})
    assert board.plan_capacity == 5
  end

  test "is capped by the sum of machine caps" do
    walk =
      walk(%{@a => 10}, %{"local" => 2, "n1" => 1}, %{
        "bd-1" => [%{pool: @a, nodes: ["local"]}]
      })

    board = derive(%{issues: [ready("bd-1")], walk: walk})
    assert board.plan_capacity == 3
  end

  test "an unlimited side yields to the finite one" do
    walk =
      walk(%{@a => :unlimited}, %{"local" => 4}, %{"bd-1" => [%{pool: @a, nodes: ["local"]}]})

    assert derive(%{issues: [ready("bd-1")], walk: walk}).plan_capacity == 4
  end

  test "with no Ready card, every pool counts" do
    board = derive(%{walk: walk(%{@a => 2, @b => 3}, %{"local" => 9}, %{})})
    assert board.plan_capacity == 5
  end

  test "no walk, no capacity" do
    assert derive(%{}).plan_capacity == 0
  end

  describe "CapacityExplainer.cap/2" do
    test "reads the plan-time capacity, not the capacity terms' effective" do
      terms = %{
        effective: 99,
        binding: :nodes,
        terms: [nodes: 99],
        account: nil,
        placement: %{mode: :local_only, cap: 99, free: 99},
        install: %{sum: 99, local: 99, nodes: [], remote_execution?: true}
      }

      board = derive(%{walk: walk(%{@a => 4}, %{"local" => 6}, %{}), capacity: terms})
      cap = CapacityExplainer.cap(board)
      assert cap.effective == 4
      assert cap.free == 4
      assert cap.binding == :budget
      assert cap.headline =~ "provider budget"
      assert [%{key: :budget, binding?: true}] = Enum.filter(cap.limits, & &1.binding?)
    end
  end
end
