defmodule Wardmast.Board.AutopilotEnforceTest do
  @moduledoc """
  Autopilot under the seat walk (DC8, DC12; design
  `provider-dynamic-concurrency.md` §4.3, §4.4):

    * the walk decides: the pass dispatches the walk's first placement, with its
      pair riding in as `planned: %{account_id, pool, node}`;
    * a board with no walk (its inputs failed) dispatches nothing that pass;
    * a budget that rises plans a pass, like a freed slot; a fall does not;
    * a resume deferred for a slot is replayed when its own pool has a seat,
      whatever the board's slot count says.

  """
  use ExUnit.Case, async: true

  alias Wardmast.Board.Autopilot

  @pool {"acct", "claude"}
  @other_pool {"acct-2", "codex"}

  defp entry(id, state, opts \\ []) do
    %{
      id: id,
      state: state,
      reason: Keyword.get(opts, :reason, "next up — dispatching..."),
      hold: Keyword.get(opts, :hold),
      card: %{id: id}
    }
  end

  # The board the walk planned: `placements` are the walk's, and every placed
  # card is a Ready entry.
  defp board(placements, opts \\ []) do
    walk_entries =
      for %{id: id} = placement <- placements do
        %{entry(id, :next) | hold: nil}
        |> Map.merge(%{wait_cause: nil, pair: %{pool: placement.pool, node: placement.node}})
      end

    base = %{
      ready: walk_entries,
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      slots_total: 4,
      paused: false,
      now: DateTime.utc_now()
    }

    if Keyword.get(opts, :walk?, true) do
      Map.put(base, :walk, %{
        promote: placements |> List.first() |> then(&(&1 && &1.id)),
        placements: placements,
        entries: walk_entries,
        pools: %{
          @pool => %{budget: 3, seats: 1, cap: 3, label: "claude:default", reason: "5h"},
          @other_pool => %{budget: 2, seats: 0, cap: nil, label: "codex:default", reason: "5h"}
        },
        nodes: %{"local" => %{cap: 6, used: 1, label: "local"}}
      })
    else
      base
    end
  end

  defp start(board_fun, opts \\ []) do
    test = self()

    defaults = [
      name: nil,
      paused: false,
      interval_ms: :never,
      debounce_ms: 20,
      topics: [],
      follow_up: false,
      registry_settled?: fn -> true end,
      snapshot: fn _opts -> board_fun.() end,
      dispatch: fn id, extra ->
        send(test, {:dispatched, id, extra})
        {:ok, %{task_id: id}}
      end,
      resume: fn task_id, kind, opts ->
        send(test, {:resumed, task_id, kind, opts})
        {:ok, %{task_id: task_id}}
      end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "the walk decides" do
    test "the walk's placement goes, with its planned pair" do
      placements = [%{id: "bd-2", pool: @pool, node: "local"}]
      pid = start(fn -> board(placements) end)

      assert {:ok, "bd-2"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-2", extra}

      assert extra[:planned] == %{account_id: "acct", pool: "claude", node: "local"}
      refute Keyword.has_key?(extra, :admission_shadow)
    end

    test "with nothing placed, nothing goes" do
      pid = start(fn -> board([]) end)

      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "an unmetered pool's placement plans its machine only" do
      placements = [%{id: "bd-1", pool: {:unmetered, "ollama"}, node: "local"}]
      pid = start(fn -> board(placements) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", extra}
      assert extra[:planned] == %{account_id: nil, pool: nil, node: "local"}
    end
  end

  @tag capture_log: true
  test "a walk with no entries or placements dispatches nothing, and an idle pass survives it" do
    broken = Map.put(board([], walk?: false), :walk, %{promote: nil})
    pid = start(fn -> broken end)

    assert :idle = Autopilot.tick(pid)
    assert Process.alive?(pid)
    assert [] = :sys.get_state(pid).holds
  end

  test "a board without a walk dispatches nothing (there is no head-of-line fallback)" do
    pid = start(fn -> board([], walk?: false) end)

    assert :idle = Autopilot.tick(pid)
    refute_received {:dispatched, _, _}
  end

  describe "a budget change (E8)" do
    test "a rise plans a pass, like a freed seat" do
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(fn -> board(placements) end)

      send(pid, {:budget_changed, %{account: "acct", pool: "claude"}, 1, 2, "5h"})
      assert_receive {:dispatched, "bd-1", _extra}, 1_000
    end

    test "a fall plans nothing" do
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(fn -> board(placements) end)

      send(pid, {:budget_changed, %{account: "acct", pool: "claude"}, 2, 1, "5h"})
      refute_receive {:dispatched, _, _}, 200
    end
  end

  describe "a resume deferred for a slot" do
    test "replayed when its pool has a seat, whatever the board's slot count says" do
      test = self()

      pid =
        start(fn -> board([]) end,
          slot_room: fn task_id, _kind ->
            send(test, {:asked, task_id})
            true
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert {:resumed, "bd-parked"} = Autopilot.tick(pid)
      assert_received {:asked, "bd-parked"}
      assert_received {:resumed, "bd-parked", :resume, opts}
      assert opts[:slot_admitted] == true
    end

    test "waits while its pool is full" do
      pid =
        start(fn -> board([]) end, slot_room: fn _task_id, _kind -> false end)

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:resumed, _, _, _}
    end
  end

  describe "a deferred resume its pool cannot admit (bd-7twuru)" do
    @blocked_pool {"acct-codex", "codex"}

    defp placement(id, pool), do: %{id: id, pool: pool, node: "local"}

    test "does not hold Ready cards of other pools" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(fn -> board(placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert {:ok, "bd-ready"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-ready", _}
      refute_received {:resumed, _, _, _}
      assert Autopilot.status(pid).deferred_resumes == ["bd-parked"]
    end

    test "still goes before Ready cards of its own pool" do
      placements = [placement("bd-same", @blocked_pool)]

      pid =
        start(fn -> board(placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "blocks the account Dispatch recorded, not the implementer's" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(fn -> board(placements) end,
          slot_room: fn _task_id, _kind -> false end,
          # the implementer is on the Ready card's (claude) account
          resume_account: fn "bd-parked" -> "acct" end
        )

      :ok =
        Autopilot.defer_resume(pid, "bd-parked", :resume, waiting_account: "acct-codex")

      assert {:ok, "bd-ready"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-ready", _}
      refute_received {:resumed, _, _, _}
      assert [%{opts: opts}] = :sys.get_state(pid).deferred_resumes
      refute Keyword.has_key?(opts, :waiting_account)
    end

    test "an entry without a recorded account falls back to the implementer's" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(fn -> board(placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "parks naming the recorded account" do
      test = self()

      pid =
        start(fn -> board([]) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct" end,
          park_after: 2,
          escalate: fn id, reason, prio ->
            send(test, {:escalated, id, reason, prio})
            :ok
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, waiting_account: "acct-codex")
      for _ <- 1..4, do: Autopilot.tick(pid)

      assert_received {:escalated, "bd-parked", {:deferred_resume_parked, "acct-codex", 2}, _}
      refute_received {:escalated, _, _, _}
    end

    test "is parked with an attention item after N stalled ticks, once" do
      test = self()

      pid =
        start(fn -> board([]) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct-codex" end,
          park_after: 3,
          escalate: fn id, reason, prio ->
            send(test, {:escalated, id, reason, prio})
            :ok
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      for _ <- 1..5, do: Autopilot.tick(pid)

      assert_received {:escalated, "bd-parked", {:deferred_resume_parked, "acct-codex", 3}, _}
      refute_received {:escalated, _, _, _}
    end

    test "status lists deferred resumes with their age, and a hold is logged" do
      import ExUnit.CaptureLog
      placements = [placement("bd-same", @blocked_pool)]

      pid =
        start(fn -> board(placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])

      log = capture_log(fn -> Autopilot.tick(pid) end)
      assert log =~ "holding Ready behind deferred resume bd-parked"
      assert log =~ "acct-codex"

      assert [%{task_id: "bd-parked", age_ms: age, wait: :slot}] =
               Autopilot.status(pid).deferred_resume_details

      assert is_integer(age) and age >= 0
    end
  end
end
