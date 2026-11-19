defmodule Wardmast.Worker.ResumeSlotTest do
  @moduledoc """
  bd-92mx1m / bd-asxw4e: a resume is gated on whether the ticket **currently
  holds a slot**, not on who is resuming it — and a ticket holds a slot
  exactly while it is In progress (`:active`), the same rule the board counts
  by (`Wardmast.Tasks.SlotGate`). An `:active` ticket passes through uncapped
  (the #1969/#1995 no-deadlock guarantee); any other re-acquires a slot like a
  new admission.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Events.Record
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker.ResumeSlot

  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-#{System.unique_integer([:positive])}",
        prefix: "rsl#{System.unique_integer([:positive])}"
      })

    {:ok, a} = Ash.create(Issue, %{title: "task A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B", workspace_id: ws.id})
    %{ws: ws, a: a, b: b}
  end

  # A ticket in `state`, as the gate would read it — the struct is never written.
  defp in_state(ticket, state), do: %{ticket | state: state}

  describe "an :active ticket holds its slot" do
    test "resuming it needs no new slot, at a full cap, whoever resumes it", %{a: a, b: b} do
      a = in_state(a, :active)
      tickets = [a, in_state(b, :active)]

      for origin <- [:human, :automatic] do
        assert {:ok, :held} = ResumeSlot.admit(a, origin: origin, tickets: tickets, cap: 1)
      end
    end

    # The fix-round and reboot shapes: whatever happened to the worker (failed
    # mid hand-off, cut off by a restart, parked on a human), the ticket never
    # left In progress, so it never gave its slot up.
    test "whatever its worker did — no worker rows are read at all", %{a: a, b: b} do
      a = in_state(a, :active)

      assert {:ok, :held} =
               ResumeSlot.admit(a, origin: :automatic, tickets: [in_state(b, :active)], cap: 1)
    end
  end

  describe "orphaned tickets hold no slot (bd-3fbj83)" do
  end

  describe "a ticket not In progress must acquire a slot" do
    test "force with a free slot is a plain admission, not an override", %{ws: ws, a: a} do
      assert {:ok, :acquired} = ResumeSlot.admit(a, force: true, tickets: [], cap: 1)

      assert [] =
               Record
               |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
               |> Ash.read!()
    end

    test "a resume the scheduler already admitted is not re-checked", %{a: a, b: b} do
      assert {:ok, :admitted} =
               ResumeSlot.admit(a,
                 origin: :automatic,
                 slot_admitted: true,
                 tickets: [in_state(b, :active)],
                 cap: 1
               )
    end
  end

  describe "reading the world" do
    setup do
      put_local_cap(1)
    end
  end
end
