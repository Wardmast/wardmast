defmodule WardmastWeb.Api.WorkerResumeSlotTest do
  @moduledoc """
  bd-92mx1m acceptance 2/4 on `POST /api/workers/:task_id/resume` — the
  endpoint behind `arb worker resume` (and `arb resume`). A resume of a task
  that released its slot, at a full cap, is refused with a 409 naming the cap
  and the slot-holding tasks; `"force": true` (`--force`) admits it and
  records the override.
  """
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Usage.Event, as: UsageEvent

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-resume-slot-#{System.unique_integer([:positive])}",
        prefix: "ars#{System.unique_integer([:positive])}"
      })

    incident = ResumeSlotFixture.setup_incident(ws)

    # The endpoint is a *session* resume: it needs a captured session id.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: incident.a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    Map.merge(%{conn: put_req_header(conn, "accept", "application/json"), ws: ws}, incident)
  end

  describe "refusals the endpoint used to answer with a generic 500 (bd-5fc29i)" do
    test "a resume while migrations are pending is a 503 busy naming the count", ctx do
      Application.put_env(:wardmast, :migrations_module, WardmastWeb.Test.PendingMigrations)
      on_exit(fn -> Application.delete_env(:wardmast, :migrations_module) end)

      conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

      assert %{"error" => %{"type" => "busy", "message" => message, "details" => details}} =
               json_response(conn, 503)

      assert message =~ "pending migration"
      assert details["pending_migrations"] == 3
    end

    test "a resume when the migration check itself fails is a 503 busy, not a 500", ctx do
      Application.put_env(:wardmast, :migrations_module, WardmastWeb.Test.UnreachableMigrations)
      on_exit(fn -> Application.delete_env(:wardmast, :migrations_module) end)

      conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

      assert %{"error" => %{"type" => "busy", "details" => %{"reason" => ":unreachable"}}} =
               json_response(conn, 503)
    end
  end
end
