defmodule Wardmast.Board.SnapshotPairClaimTest do
  @moduledoc """
  bd-7p6a9o, acceptance 2 (the autopilot half): while a pair session is live
  on a ticket, the board holds its card — `held — claimed by a live pair
  session (…)` — so Autopilot never plans a worker onto it. The card behind it
  still goes, and ending the session releases the claim with nothing else to
  undo.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Board.Snapshot
  alias Wardmast.Sessions
  alias Wardmast.Sessions.Session
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.SessionEnv

  @now ~U[2026-11-19 12:00:00Z]

  setup do
    SessionEnv.sandbox("pair-claim")
    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "spc-#{n}", prefix: "spc#{n}", config: %{}})
    {:ok, ws: ws}
  end

  defp issue(id, ws, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "widget",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      extra
    )
  end

  defp load(ws, issues) do
    Snapshot.load(
      workspace_id: ws.id,
      issues: issues,
      workers: [],
      slots_total: 3,
      quota: :ok,
      now: @now
    )
  end

  defp ready(board), do: Map.new(board.ready, &{&1.card.id, &1})

  defp pair_session!(ws, issue_id) do
    Ash.create!(Session, %{kind: :pair, issue_id: issue_id, workspace_id: ws.id})
  end

  test "a claimed card is held, naming the session, and the card behind it goes", %{ws: ws} do
    session = pair_session!(ws, "t-1")
    issues = [issue("t-1", ws, %{priority: 1}), issue("t-2", ws)]

    ready = ready(load(ws, issues))

    assert %{state: :blocked, reason: reason, hold: {:pair_session, sid}} = ready["t-1"]
    assert sid == session.id
    assert reason =~ "held — claimed by a live pair session"
    assert %{state: :next} = ready["t-2"]
  end

  test "ending the session releases the claim", %{ws: ws} do
    session = pair_session!(ws, "t-1")
    assert %{"t-1" => %{state: :blocked}} = ready(load(ws, [issue("t-1", ws)]))

    {:ok, _ended} = Sessions.mark_ended(session, "pair session closed without done")

    assert %{"t-1" => %{state: :next}} = ready(load(ws, [issue("t-1", ws)]))
  end

  test "a refine or coordinator session claims nothing", %{ws: ws} do
    Ash.create!(Session, %{issue_id: "t-1", workspace_id: ws.id})

    assert %{"t-1" => %{state: :next}} = ready(load(ws, [issue("t-1", ws)]))
  end
end
