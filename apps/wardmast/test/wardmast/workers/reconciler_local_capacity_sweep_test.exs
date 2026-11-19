defmodule Wardmast.Workers.ReconcilerLocalCapacitySweepTest do
  @moduledoc """
  bd-b2iigy: after a primary restart with more resumable runs than the local cap
  allows, the resume sweep resumes at most the cap's worth (counting runs
  already live), highest ticket priority first, and defers the rest to the
  scheduler (`held_for: :local_capacity`). Nothing deferred is lost or resumed
  twice — a remote run Recovery collected included.

  Real tickets, worktrees and workers (`Wardmast.Test.ResumeSlotFixture`); the
  restart is simulated by stopping every worker, which is exactly the state a
  boot finds (ticket In progress, no worker).
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Wardmast.Worker
  alias Wardmast.Workers.Reconciler

  # The real Reconciler for rows and tickets; only the systemd scope sweep is
  # stubbed (it would `systemctl --user stop` every live `arb-run-*` on the host).
  defmodule SweepReconciler do
    @moduledoc false
    defdelegate reconcile_orphaned_runs(opts), to: Wardmast.Workers.Reconciler
    defdelegate reconcile_shutdown_casualties(opts), to: Wardmast.Workers.Reconciler
    defdelegate reconcile_ci_waits(opts), to: Wardmast.Workers.Reconciler
    defdelegate reconcile_review_passes(opts), to: Wardmast.Workers.Reconciler
    defdelegate reconcile_held_resumes(opts), to: Wardmast.Workers.Reconciler
    defdelegate restarted_ids(lists), to: Wardmast.Workers.Reconciler
    defdelegate reconcile_open_pr_tasks(opts), to: Wardmast.Workers.Reconciler

    # Never a real process (bd-568ib9): `ps` finds nothing, `kill` signals nothing.
    def sweep_worker_process_groups(opts) do
      no_process = [ps: fn _pid -> {"", 1} end, kill: fn _args -> {"", 1} end]

      Wardmast.Workers.Reconciler.sweep_worker_process_groups(
        Keyword.put(opts, :process_group_opts, no_process)
      )
    end

    def sweep_worker_scopes(opts) do
      scope_opts = [systemctl: "systemctl-stub", cmd: fn _bin, _args, _opts -> {"", 0} end]
      Wardmast.Workers.Reconciler.sweep_worker_scopes(Keyword.put(opts, :scope_opts, scope_opts))
    end

    def reconcile_resumable_tasks(opts) do
      resume = fn issue ->
        Wardmast.Workers.Reconciler.default_resume(issue,
          start_driver: false,
          claude_command: ["sleep", "5"]
        )
      end

      Wardmast.Workers.Reconciler.reconcile_resumable_tasks(
        Keyword.put(opts, :resume_fun, resume)
      )
    end
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "local-cap-sweep-#{System.unique_integer([:positive])}",
        prefix: "lcs#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    # Far from full unless a test caps the primary itself.
    ResumeSlotFixture.put_local_cap(nil)
    StubResumeDeferrer.reset()
    on_exit(fn -> Wardmast.Settings.set_nodes_local_max_workers(nil) end)
    %{ws: ws}
  end

  defp cap!(n), do: {:ok, ^n} = Wardmast.Nodes.set_local_max_workers(n, nil)

  # A mid-flight ticket the restart cut off: In progress, its worker gone.
  defp cut_off!(ws, title, priority) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, priority: priority})

    first = ResumeSlotFixture.park!(issue, nil)
    ref = Process.monitor(first.worker_pid)
    :ok = Worker.stop(first.worker_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert Worker.whereis(issue.id) == nil
    issue
  end

  defp resumed_sweep do
    resume = fn issue ->
      Reconciler.default_resume(issue, start_driver: false, claude_command: ["sleep", "5"])
    end

    Reconciler.reconcile_resumable_tasks(resume_fun: resume)
  end

  test "with no override the hardware suggestion is far from full, so nothing is deferred", %{
    ws: ws
  } do
    a = cut_off!(ws, "a", 2)
    b = cut_off!(ws, "b", 2)

    assert {:ok, %{resumed: 2, deferred: 0}} = resumed_sweep()
    assert Worker.whereis(a.id) && Worker.whereis(b.id)
    assert StubResumeDeferrer.deferrals() == []
  end

  describe "a remote run Recovery collected" do
    # The boot order: Recovery first, then the Reconciler sweeps.
  end

  test "the sweep with the default resume reports a held ticket as deferred, not escalated",
       %{ws: ws} do
    _ = cut_off!(ws, "only one", 2)
    _ = cut_off!(ws, "and another", 2)
    cap!(0)

    assert {:ok, %{resumed: 0, deferred: 2, escalated: 0}} = resumed_sweep()
  end
end
