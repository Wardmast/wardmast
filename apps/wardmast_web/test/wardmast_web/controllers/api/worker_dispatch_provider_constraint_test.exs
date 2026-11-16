defmodule WardmastWeb.Api.WorkerDispatchProviderConstraintTest do
  @moduledoc """
  bd-13pqcp on `POST /api/workers/dispatch` — the endpoint behind `arb
  dispatch`. A ticket whose provider constraint leaves no eligible provider is
  a 409 naming the constraint (`held — provider constraint (...)`) and starts
  nothing. (An explicit `--provider` that violates it is refused the same way —
  `Wardmast.Worker.ProviderConstraintDispatchTest` covers that against stubbed
  agent binaries, which this endpoint test deliberately does not spawn.)
  """
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Worker

  setup %{conn: conn} do
    ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-constraint-#{System.unique_integer([:positive])}",
        prefix: "apc#{System.unique_integer([:positive])}",
        config: %{"agent" => %{"type" => ["claude"]}}
      })

    {:ok, task} =
      Ash.create(Issue, %{
        title: "no claude here",
        workspace_id: ws.id,
        provider_constraint: %{"exclude" => ["claude"]}
      })

    %{conn: put_req_header(conn, "accept", "application/json"), ws: ws, task: task}
  end

  defp params(ctx, extra) do
    Map.merge(
      %{
        "task_id" => ctx.task.id,
        "repo" => ResumeSlotFixture.repo(),
        "force" => true,
        "no_agent" => true
      },
      extra
    )
  end

  test "no eligible provider is a 409 naming the constraint, and nothing starts", ctx do
    conn = post(ctx.conn, ~p"/api/workers/dispatch", params(ctx, %{}))

    body = json_response(conn, 409)
    assert body["error"]["message"] =~ "held — provider constraint (exclude claude"
    assert Worker.whereis(ctx.task.id) == nil
  end

  test "a ticket without a constraint dispatches as before", ctx do
    {:ok, plain} = Ash.create(Issue, %{title: "plain", workspace_id: ctx.ws.id})

    conn =
      post(ctx.conn, ~p"/api/workers/dispatch", params(ctx, %{"task_id" => plain.id}))

    assert json_response(conn, 201)
    assert is_pid(Worker.whereis(plain.id))
  end
end
