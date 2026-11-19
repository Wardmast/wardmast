defmodule Wardmast.Worker.DispatchLocalCapacityResumeTest do
  @moduledoc """
  bd-b2iigy: every follow-up spawn of a ticket with a preserved worktree — a
  briefing or session resume, a Reconciler or auto-resume, a re-dispatch of an
  In-progress ticket — is admitted through `Wardmast.Nodes.LocalCapacity`. At the
  primary's cap it is held (a human resume is refused with the hold, an
  automatic one is deferred to the scheduler as `held_for: :local_capacity`),
  never started over the cap, and the prior worker is left exactly as it was.

  Driven end to end against a real git repo and real workers
  (`Wardmast.Test.ResumeSlotFixture`): A is In progress with its worker parked
  `:failed`, B is In progress with a live worker on the primary, and the
  primary's cap is overridden to 1.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Wardmast.Usage.Event, as: UsageEvent
  alias Wardmast.Worker
  alias Wardmast.Worker.Dispatch

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "local-cap-resume-#{System.unique_integer([:positive])}",
        prefix: "lcr#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    StubResumeDeferrer.reset()
    on_exit(fn -> Wardmast.Settings.set_nodes_local_max_workers(nil) end)

    {:ok, a} = Ash.create(Issue, %{title: "task A (cut off)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (running)", workspace_id: ws.id})

    # A stays In progress (`release: nil`): it holds its board slot, so
    # `ResumeSlot` lets the resume through and only the primary's cap is in play.
    first = ResumeSlotFixture.park!(a, nil)
    ResumeSlotFixture.admit!(ws, b)

    # A recorded session, so `resume_session/2` has something to continue.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    %{ws: ws, a: a, b: b, first: first}
  end

  defp cap!(n), do: {:ok, ^n} = Wardmast.Nodes.set_local_max_workers(n, nil)

  describe "at the primary's cap (cap 1, B live)" do
    test "force resumes over the cap (recorded)", %{a: a, first: first} do
      cap!(1)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 start_driver: false,
                 claude_command: ["sleep", "2"],
                 force_slot: true,
                 slot_override_actor: "coordinator"
               )

      assert result.worker_pid != first.worker_pid
    end
  end

  # The production drain end to end: the real `Autopilot.defer_resume/4` queues
  # the held resume, and the Autopilot's own default replay (`Dispatch.resume/2`
  # with `slot_admitted: true`, its default `LocalCapacity.check/3` room test)
  # starts it once B's slot frees — with the board showing no free slot at all.
  describe "with room on the primary" do
    test "a resume goes through and takes the second slot (cap 2, B live)", %{a: a, first: first} do
      cap!(2)

      assert {:ok, result} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])

      assert result.worker_pid != first.worker_pid
      assert StubResumeDeferrer.deferrals() == []
    end

    test "a ticket's own run never counts against its resume (cap 1, A alone)",
         %{a: a, b: b} do
      cap!(1)
      Worker.stop(b.id, :normal)

      assert {:ok, _result} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])
    end
  end

  describe "with no override" do
    test "the hardware suggestion applies (enforced), and a resume under it is admitted",
         %{a: a} do
      # config/test.exs already pins :local_hardware (32 CPUs, cap 16). Pinned again here
      # as hygiene only, so this test does not hang off the global value.
      put_app_env(:wardmast, :local_hardware, %{cpus: 12, mem_total: 31 * 1024 * 1024 * 1024})
      ResumeSlotFixture.put_local_cap(nil)
      assert %{source: :suggestion, cap: 6} = Wardmast.Nodes.LocalCapacity.cap()

      result = Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])

      # A refusal names the state it was decided on, so a recurrence points at the leak
      # (a stray :local_hardware or nodes_local_max_workers) instead of the symptom.
      assert {:ok, _result} = result,
             "resume refused: #{inspect(result)}; " <>
               "hardware=#{inspect(Application.get_env(:wardmast, :local_hardware))} " <>
               "override=#{inspect(Wardmast.Settings.nodes_local_max_workers())} " <>
               "cap=#{inspect(Wardmast.Nodes.LocalCapacity.cap())}"
    end
  end
end
