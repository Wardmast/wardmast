defmodule WardmastWeb.Api.WorkerDispatchRepoCapTest do
  @moduledoc """
  DC9 (bd-7oy77e) on `POST /api/workers/dispatch` — the endpoint behind
  `arb dispatch`. A fresh dispatch into a
  repo at its `worker.repos.<repo>.max_concurrent` is a 409 naming the repo, its
  cap and the holders; `"over_cap": true` goes over and records the override.
  """
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Worker
  alias Wardmast.Worker.RepoCap

  require Ash.Query

  @repo ResumeSlotFixture.repo()

  setup %{conn: conn} do
    ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)

    ws =
      Ash.create!(Workspace, %{
        name: "api-repo-cap-#{System.unique_integer([:positive])}",
        prefix: "arc#{System.unique_integer([:positive])}",
        config: %{"worker" => %{"repos" => %{@repo => %{"max_concurrent" => 1}}}}
      })

    {:ok, holder} = Ash.create(Issue, %{title: "holder", workspace_id: ws.id})
    test = self()

    pid =
      spawn(fn ->
        send(test, {:held, RepoCap.admit(holder, @repo)})

        receive do
          :release -> :ok
        end
      end)

    on_exit(fn -> send(pid, :release) end)
    assert_receive {:held, {:ok, :admitted}}, WardmastWeb.Test.Timing.scale(5_000)

    {:ok, task} = Ash.create(Issue, %{title: "to dispatch", workspace_id: ws.id})

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      ws: ws,
      holder: holder,
      task: task
    }
  end

  defp params(ctx, extra) do
    Map.merge(
      %{"task_id" => ctx.task.id, "repo" => @repo, "force" => true, "no_agent" => true},
      extra
    )
  end

  test "a dispatch into a full repo is a 409 naming the repo, the cap and the holder", ctx do
    conn = post(ctx.conn, ~p"/api/workers/dispatch", params(ctx, %{"no_agent" => false}))

    body = json_response(conn, 409)
    assert body["error"]["message"] =~ "repo #{@repo}"
    assert body["error"]["message"] =~ "--over-cap"
    assert body["error"]["details"]["cap"] == 1
    assert body["error"]["details"]["holders"] == [ctx.holder.id]
    assert body["error"]["details"]["repo"] == @repo

    assert Worker.whereis(ctx.task.id) == nil
  end

  test "over_cap: true goes over the cap and records the override", ctx do
    conn =
      post(
        ctx.conn,
        ~p"/api/workers/dispatch",
        params(ctx, %{"no_agent" => false, "over_cap" => true})
      )

    assert json_response(conn, 201)
    assert is_pid(Worker.whereis(ctx.task.id))

    assert [event] =
             Wardmast.Events.Record
             |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "repo_cap_override")
             |> Ash.read!()

    assert event.payload["task_id"] == ctx.task.id
    assert event.payload["actor"] == "coordinator"
  end
end
