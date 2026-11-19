defmodule WardmastWeb.Api.IssuePairControllerTest do
  @moduledoc """
  bd-7p6a9o: the REST twins of `ward pair <ticket>`, `ward pair done <ticket>`
  and `ward pair end <ticket>` — `POST /api/issues/:id/pair`, `POST
  /api/issues/:id/pair/done` and `DELETE /api/issues/:id/pair`.
  """
  use WardmastWeb.ConnCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.GitFixture
  alias Wardmast.Test.SessionEnv
  alias Wardmast.Test.SessionRunnerStub

  setup %{conn: conn} do
    SessionEnv.sandbox("pair-api")
    SessionRunnerStub.reset()
    Wardmast.DataCase.put_app_env(:wardmast, :sessions_runner, SessionRunnerStub)
    git = GitFixture.forge_and_checkout()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-api-#{System.unique_integer([:positive])}",
        prefix: "pa#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
        }
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Make widgets faster",
        acceptance: "- faster",
        workspace_id: ws.id,
        repo: "widget",
        issue_type: :feature
      })

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"), issue: put_state!(issue, :queued)}
  end

  test "POST /api/issues/:id/pair opens the pair session, and again reopens it", %{
    conn: conn,
    issue: issue
  } do
    first = conn |> post(~p"/api/issues/#{issue.id}/pair") |> json_response(200)
    assert %{"data" => %{"session_id" => sid, "reopened" => false, "worktree" => wt}} = first
    assert File.dir?(wt)

    again = conn |> post(~p"/api/issues/#{issue.id}/pair") |> json_response(200)
    assert %{"data" => %{"session_id" => ^sid, "reopened" => true}} = again
  end

  test "a ticket that cannot be paired on is a 409 with the reason", %{conn: conn, issue: issue} do
    merging = put_state!(issue, :merging)
    body = conn |> post(~p"/api/issues/#{merging.id}/pair") |> json_response(409)
    assert inspect(body) =~ "cannot be paired on"
  end

  test "POST /api/issues/:id/pair/done refuses nothing committed with a 409", %{
    conn: conn,
    issue: issue
  } do
    {:ok, _} = Pair.open(issue, runner: SessionRunnerStub)

    body = conn |> post(~p"/api/issues/#{issue.id}/pair/done") |> json_response(409)
    assert inspect(body) =~ "no commits"
    assert {:ok, _still_live} = Pair.live_session(issue.id)
  end

  test "DELETE /api/issues/:id/pair ends it; a second end is a 404", %{conn: conn, issue: issue} do
    {:ok, %{session: session}} = Pair.open(issue, runner: SessionRunnerStub)

    ended = conn |> delete(~p"/api/issues/#{issue.id}/pair") |> json_response(200)
    assert %{"data" => %{"session_id" => sid, "status" => "ended"}} = ended
    assert sid == session.id
    assert File.dir?(session.cwd)

    gone = conn |> delete(~p"/api/issues/#{issue.id}/pair") |> json_response(404)
    assert inspect(gone) =~ "no live pair session"
  end
end
