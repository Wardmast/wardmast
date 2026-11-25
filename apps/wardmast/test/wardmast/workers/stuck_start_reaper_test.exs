defmodule Wardmast.Workers.StuckStartReaperTest do
  @moduledoc """
  bd-c845gp / GitHub #1657: a run left in `starting` with no live agent past a
  timeout is reaped (its worker stopped, its row ended `interrupted`) and so
  stops being reported as an active worker by `worker_list` / `arb prime`.
  """

  # async: false: the worker process reaches the same sandboxed connection.
  use Wardmast.DataCase, async: false

  alias Wardmast.Worker
  alias Wardmast.Workers.Current
  alias Wardmast.Workers.Run
  alias Wardmast.Workers.StuckStartReaper

  require Ash.Query

  defp start_ghost(task_id) do
    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "arbiter",
        workspace_id: nil,
        meta: %{role: :implementer, revises: Wardmast.Worker.ReviewGate.base_task_id(task_id)}
      )

    pid
  end

  defp run_for(task_id) do
    Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read_one!()
  end

  defp later(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  test "a worker stuck in :starting with no agent past the timeout is stopped and its run ended" do
    base = "bd-ghost-#{System.unique_integer([:positive])}"
    id = base <> "#review#impl1"
    pid = start_ghost(id)
    ref = Process.monitor(pid)
    assert %{state: :starting, agent_live: false} = Worker.state(pid)

    assert %{workers: [^id]} =
             StuckStartReaper.sweep(now: later(StuckStartReaper.timeout_ms() + 1_000))

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, Wardmast.Test.Timing.scale(5_000)
    assert Worker.whereis(id) == nil

    run = run_for(id)
    assert {run.state, run.outcome} == {:finished, :interrupted}
    assert run.failure_reason =~ "starting"
  end

  test "a worker that has only just started is left alone" do
    id = "bd-fresh-#{System.unique_integer([:positive])}#review#impl1"
    pid = start_ghost(id)

    assert %{workers: [], runs: []} = StuckStartReaper.sweep()

    assert Worker.whereis(id) == pid
    assert run_for(id).state == :starting
    Worker.stop(pid, :normal)
  end

  test "a :starting run row with no live worker past the timeout is ended; a fresh one is not" do
    stale = "bd-ghost-row-#{System.unique_integer([:positive])}#review#impl1"
    fresh = "bd-fresh-row-#{System.unique_integer([:positive])}"

    for {id, started} <- [{stale, later(-3 * 3_600_000)}, {fresh, DateTime.utc_now()}] do
      Ash.create!(Run, %{
        task_id: id,
        repo: "arbiter",
        workspace_id: "ws-reap",
        state: :starting,
        started_at: started,
        output_lines: []
      })
    end

    assert %{runs: [^stale]} = StuckStartReaper.sweep()

    assert {run_for(stale).state, run_for(stale).outcome} == {:finished, :interrupted}
    assert run_for(fresh).state == :starting
  end

  # Review finding: a worker holding at :starting for a resume backoff or a quota
  # wait has agent_live false and an old started_at, but its session is on record.
  test "a worker holding at :starting after its session exited (resume backoff) is not reaped" do
    id = "bd-backoff-#{System.unique_integer([:positive])}"
    pid = start_ghost(id)

    :sys.replace_state(pid, fn st ->
      session = %{exited_at: DateTime.utc_now(), started_at: DateTime.utc_now()}
      %{st | claude_sessions: %{make_ref() => session}}
    end)

    assert %{state: :starting, agent_live: false, session_opened: true} = Worker.state(pid)

    assert %{workers: []} =
             StuckStartReaper.sweep(now: later(StuckStartReaper.timeout_ms() + 1_000))

    assert Worker.whereis(id) == pid
    assert run_for(id).state == :starting
    Worker.stop(pid, :normal)
  end

  # Review nit: a live worker owns its task's run rows even when the snapshot probe
  # that would carry its run_id timed out; ownership also matches on task id.
  test "a stale :starting row whose task id a live worker holds is left alone" do
    id = "bd-owned-#{System.unique_integer([:positive])}"
    pid = start_ghost(id)

    row =
      Ash.create!(Run, %{
        task_id: id,
        repo: "arbiter",
        workspace_id: "ws-reap",
        state: :starting,
        started_at: later(-3 * 3_600_000),
        output_lines: []
      })

    assert %{runs: []} = StuckStartReaper.sweep()
    assert Ash.get!(Run, row.id).state == :starting
    Worker.stop(pid, :normal)
  end

  test "the reaped run no longer shows as an active worker" do
    base = "bd-ghost-list-#{System.unique_integer([:positive])}"
    id = base <> "#review#impl1"
    start_ghost(id)

    assert Enum.any?(Current.list(), &(&1.ticket_id == base))

    StuckStartReaper.sweep(now: later(StuckStartReaper.timeout_ms() + 1_000))

    refute Enum.any?(Current.list(), &(&1.ticket_id == base and &1.source == :live))
  end
end
