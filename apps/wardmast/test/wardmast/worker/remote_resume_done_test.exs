defmodule Wardmast.Worker.RemoteResumeDoneTest do
  @moduledoc """
  bd-361rwu (#1316) — a send-back resume (`arb worker resume`) placed on a cluster node
  prints `arb done` while its container is still running; the node's final checkout upload
  (the agent's new commit) reaches the home clone only with the exit. The author run must
  not enter the commit gate / ReviewGate until that upload has landed: the gate otherwise
  reads, pushes and reviews the home clone's OLD head, the new commit arrives afterwards
  and is never pushed, and `SendBackBrief.flag_unchanged_head/3` pages "produced no new
  commit" for a run that did commit.

  bd-bg87oz fixed this for fix and conflict passes only. The remote session is simulated
  as in `Wardmast.Worker.RemotePassDoneTest`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Worker

  @handle {:remote, {"node-a", "run-1", :ref}}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    task_id = "bd-rrd-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "r",
        meta: %{
          resume: true,
          issue_type: :bug,
          branch: "bugfix/x",
          worktree_path: tmp_dir
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    %{pid: pid}
  end

  defp put_session(pid, session) do
    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, @handle, session)}
    end)
  end

  defp signal_done(pid) do
    send(pid, {:__claude_session_done__, "arb done"})
    _ = :sys.get_state(pid)
    :ok
  end

  test "a resumed author run whose node run is still live waits for the exit", %{pid: pid} do
    put_session(pid, %{exit_status: nil})

    signal_done(pid)

    state = Worker.state(pid)
    assert state.state in [:working, :starting]
    assert state.waiting_on != :review_gate
    assert state.meta.done_seen == true
  end

  test "a final checkout the node could not upload fails the run instead of reviewing a stale clone",
       %{pid: pid} do
    put_session(pid, %{exit_status: 0, remote_outcome: %{checkout_failed?: true}})

    signal_done(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    assert inspect(Worker.state(pid).meta.failure_reason) =~ "remote_checkout_failed"
  end

  test "once the node run has exited with its checkout ingested the same done signal proceeds",
       %{pid: pid} do
    put_session(pid, %{exit_status: nil})
    signal_done(pid)
    assert %{state: run_state} = Worker.state(pid)
    assert run_state in [:working, :starting]

    put_session(pid, %{exit_status: 0, remote_outcome: %{checkout_failed?: false}})
    signal_done(pid)

    # Past the wait: the commit gate / completion path ran (it has no merger in this
    # fixture, so it ends the run), and the stale-clone failure did not fire.
    state = Worker.state(pid)
    refute state.state in [:working, :starting]
    refute inspect(Map.get(state.meta, :failure_reason)) =~ "remote_checkout_failed"
  end
end
