defmodule Wardmast.Worker.DispatchPairClaimTest do
  @moduledoc """
  bd-7p6a9o, acceptance 2 (the dispatch half): while a pair session is live on
  a ticket, no worker starts on it — not a manual dispatch, not a forced one,
  not a resume — and the refusal names the pair session as the hold. Ending
  the session releases the claim with nothing else to undo.

  `Wardmast.Worker.start/1` holds the same line for the callers that never go
  through `Wardmast.Worker.Dispatch` (the merge queue's fix and conflict
  passes), but not for the ReviewGate's `#`-keyed reviewer sessions, which
  read a PR and never touch the ticket's worktree.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Sessions
  alias Wardmast.Sessions.Session
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.SessionEnv
  alias Wardmast.Worker
  alias Wardmast.Worker.Dispatch

  setup do
    SessionEnv.sandbox("pair-dispatch")

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-dispatch-#{System.unique_integer([:positive])}",
        prefix: "pd#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      for w <- Worker.list_children(), w.workspace_id == ws.id do
        _ = Worker.stop(w.task_id, :normal)
      end
    end)

    {:ok, issue} = Ash.create(Issue, %{title: "paired", workspace_id: ws.id, acceptance: "- ok"})
    task = Ash.update!(issue, %{}, action: :promote_to_ready)
    session = Ash.create!(Session, %{kind: :pair, issue_id: task.id, workspace_id: ws.id})

    %{ws: ws, task: task, session: session}
  end

  defp dispatch(task, opts \\ []),
    do: Dispatch.dispatch(task.id, Keyword.merge([repo: "r", start_driver: false], opts))

  describe "a dispatch of a ticket a pair session claims" do
    test "is refused, naming the pair session, and nothing moves", %{task: task, session: s} do
      sid = s.id
      assert {:error, {:not_dispatchable, id, {:pair_session, ^sid} = hold}} = dispatch(task)
      assert id == task.id

      message = Dispatch.refusal_message(id, hold)
      assert message =~ "pair session"
      assert message =~ String.slice(sid, 0, 8)
      # Unlike every other hold, there is no force to suggest: force cannot lift it.
      refute message =~ "force"

      assert Ash.get!(Issue, task.id).state == :queued
      assert Worker.whereis(task.id) == nil
    end

    test "is refused even when forced", %{task: task, session: s} do
      sid = s.id

      assert {:error, {:not_dispatchable, _, {:pair_session, ^sid}}} =
               dispatch(task, force: true, dispatched_by: "cli")

      assert Worker.whereis(task.id) == nil
    end

    test "is refused for Autopilot with the same hold", %{task: task, session: s} do
      sid = s.id

      assert {:error, {:not_dispatchable, _, {:pair_session, ^sid}}} =
               dispatch(task, dispatched_by: "autopilot")
    end

    test "a resume is refused too", %{task: task, session: s} do
      sid = s.id

      assert {:error, {:not_dispatchable, _, {:pair_session, ^sid}}} =
               Dispatch.resume(task.id, start_driver: false)
    end

    test "ending the session releases the claim", %{task: task, session: session} do
      {:ok, _ended} = Sessions.mark_ended(session, "pair session closed without done")

      assert {:ok, result} = dispatch(task)
      assert result.task.state == :active
    end
  end

  describe "Worker.start/1" do
    test "refuses a worker on a claimed ticket", %{ws: ws, task: task, session: s} do
      sid = s.id

      assert {:error, {:not_dispatchable, id, {:pair_session, ^sid}}} =
               Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      assert id == task.id
    end

    test "still starts the ReviewGate's reviewer, which never touches the worktree", %{
      ws: ws,
      task: task
    } do
      assert {:ok, pid} =
               Worker.start(
                 task_id: task.id <> "#review",
                 registry_key: task.id <> "#review",
                 repo: "r",
                 workspace_id: ws.id
               )

      GenServer.stop(pid, :normal)
    end
  end
end
