defmodule Wardmast.Worker.DispatchResumeSlotTest do
  @moduledoc """
  bd-92mx1m: `Dispatch.resume/2` and `Dispatch.resume_session/2` consult
  `Wardmast.Worker.ResumeSlot` before re-entering a task. Driven end to end
  against a real git repo and real workers, so the gate is proven where it
  actually sits — after the resume's own validity checks, before the prior
  worker is stopped.

  bd-asxw4e: a ticket holds a slot exactly while it is In progress (`:active`).
  So the full cap here is A Merging on its open PR (no slot) and B In
  progress (the one slot); a resume of A must acquire a slot, and a resume of
  a ticket still In progress passes through uncapped.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Wardmast.Worker
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Workers.Reconciler

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-dispatch-#{System.unique_integer([:positive])}",
        prefix: "rsd#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    StubResumeDeferrer.reset()

    {:ok, a} = Ash.create(Issue, %{title: "task A (parked)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (admitted)", workspace_id: ws.id})

    %{ws: ws, a: a, b: b}
  end

  # Task A ran and parked (its worker lingers :failed), and its PR opened: it
  # is Merging, which holds no slot. `release: nil` keeps it In progress.
  defp park_a(a, release \\ :merging), do: ResumeSlotFixture.park!(a, release)

  # Task B was admitted into the slot A freed: In progress.
  # On a node, so these tests exercise `ResumeSlot`'s board cap alone and the
  # primary's own (enforced) cap never defers the resume under test.
  defp admit_b(ws, b), do: ResumeSlotFixture.admit!(ws, b, node_id: "node-b")

  defp overrides(ws), do: ResumeSlotFixture.overrides(ws)

  describe "the boot reconciler" do
    # After a reboot nothing is registered for A. A ticket still In progress
    # holds its own slot, whatever cut its run off, so the reconciler resumes
    # it for real at a full cap rather than deferring it.
    test "resumes a ticket In progress uncapped", %{ws: ws, a: a, b: b} do
      first = park_a(a, nil)
      admit_b(ws, b)
      Worker.stop(a.id, :normal)
      refute Process.alive?(first.worker_pid)

      assert {:ok, %{resumed: 1, escalated: 0}} =
               Reconciler.reconcile_resumable_tasks(
                 resume_fun: fn issue ->
                   Dispatch.resume(issue.id,
                     resume_origin: :automatic,
                     start_driver: false,
                     claude_command: ["sleep", "2"]
                   )
                 end
               )

      assert StubResumeDeferrer.deferrals() == []
      assert Worker.whereis(a.id) not in [nil, first.worker_pid]
      assert overrides(ws) == []
    end
  end

  describe "a resume of a task that still holds its slot" do
    # Acceptance 1: the fix-round shape. The ReviewGate rejected the author and
    # its implementer round replaces it; the ticket is still In progress, so
    # the round spawns even though the cap is full — #1969/#1995's no-deadlock
    # rule. (bd-741sid: the ticket's state holds the slot; there is no longer a
    # `slot_handoff` marker on the failed author.)
    test "a ReviewGate fix round spawns at a full cap", %{ws: ws, a: a, b: b} do
      first = park_a(a, nil)
      admit_b(ws, b)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> flunk("a held slot must not defer") end,
                 review_gate_fix_round_attempts: 1,
                 start_driver: false,
                 claude_command: ["sleep", "2"]
               )

      assert result.worker_pid != first.worker_pid
      assert overrides(ws) == []
    end
  end

  describe "resume_session/2" do
  end
end
