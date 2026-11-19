defmodule WardmastWeb.Api.AttachmentControllerTest do
  @moduledoc "`POST|GET /api/issues/:task_id/attachments` — the REST twin of `ticket_attach` / `ticket_attachment_list`."
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
  alias Wardmast.MCP.Scope
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:wardmast, :attachments)
    Application.put_env(:wardmast, :attachments, root: dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardmast, :attachments, previous),
        else: Application.delete_env(:wardmast, :attachments)
    end)

    ws = Ash.create!(Workspace, %{name: "att-api-a", prefix: "aaa"})
    other_ws = Ash.create!(Workspace, %{name: "att-api-b", prefix: "aab"})
    mine = make_issue(ws, "mine")
    sibling = make_issue(ws, "sibling")
    foreign = make_issue(other_ws, "foreign")

    {:ok, ws: ws, mine: mine, sibling: sibling, foreign: foreign}
  end

  defp make_issue(ws, title),
    do: Ash.create!(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ac"})

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(data, extra \\ %{}), do: Map.put(extra, "data", Base.encode64(data))

  test "a coordinator attaches and lists", %{conn: conn, mine: mine} do
    conn =
      post(
        conn,
        ~p"/api/issues/#{mine.id}/attachments",
        body(Fixture.png(64, 32), %{"caption" => "hi", "role" => "before", "shot_id" => "home"})
      )

    assert %{
             "attachment" => %{"id" => id, "source" => "coordinator", "width" => 64, "url" => url}
           } =
             json_response(conn, 201)

    assert url == "/attachments/#{id}"

    listed =
      conn
      |> recycle_with_token()
      |> get(~p"/api/issues/#{mine.id}/attachments")
      |> json_response(200)

    assert %{
             "task_id" => _,
             "attachments" => [%{"id" => ^id, "caption" => "hi", "role" => "before"}]
           } = listed
  end

  defp recycle_with_token(_conn), do: coordinator_conn()

  test "a worker attaches to and lists its own ticket", %{mine: mine} do
    token = Scope.mint_worker(mine)

    created =
      token
      |> as()
      |> post(~p"/api/issues/#{mine.id}/attachments", body(Fixture.jpeg()))
      |> json_response(201)

    assert %{"attachment" => %{"source" => "worker", "content_type" => "image/jpeg"}} = created

    assert %{"attachments" => [_]} =
             token |> as() |> get(~p"/api/issues/#{mine.id}/attachments") |> json_response(200)
  end

  test "a worker is refused another ticket's attachments, even in its own workspace", %{
    mine: mine,
    sibling: sibling
  } do
    token = Scope.mint_worker(mine)

    assert token
           |> as()
           |> post(~p"/api/issues/#{sibling.id}/attachments", body(Fixture.png()))
           |> json_response(403)

    assert token |> as() |> get(~p"/api/issues/#{sibling.id}/attachments") |> json_response(403)
    assert Attachments.list(sibling.id) == []
  end

  test "a workspace-bound coordinator cannot reach another workspace's ticket", %{
    ws: ws,
    foreign: foreign
  } do
    token = Scope.mint_coordinator(ws.id)

    assert token
           |> as()
           |> post(~p"/api/issues/#{foreign.id}/attachments", body(Fixture.png()))
           |> json_response(404)

    assert token |> as() |> get(~p"/api/issues/#{foreign.id}/attachments") |> json_response(404)
    assert Attachments.list(foreign.id) == []
  end

  test "an unknown ticket is a 404", %{conn: conn} do
    assert conn |> get(~p"/api/issues/nope-123/attachments") |> json_response(404)
  end

  test "a request cannot set the source", %{conn: conn, mine: mine} do
    conn =
      post(
        conn,
        ~p"/api/issues/#{mine.id}/attachments",
        body(Fixture.png(), %{"source" => "arbiter-capture"})
      )

    assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    assert Attachments.list(mine.id) == []
  end

  test "rejects an oversize image, a non-image and a missing body", %{conn: conn, mine: mine} do
    big =
      post(
        conn,
        ~p"/api/issues/#{mine.id}/attachments",
        body(Fixture.png(4, 3, bytes: 2_097_153))
      )

    assert %{"error" => %{"type" => "validation_error", "details" => %{"reason" => "too_large"}}} =
             json_response(big, 422)

    svg = post(coordinator_conn(), ~p"/api/issues/#{mine.id}/attachments", body("<svg/>"))

    assert %{"error" => %{"details" => %{"reason" => "unsupported_type"}}} =
             json_response(svg, 422)

    none = post(coordinator_conn(), ~p"/api/issues/#{mine.id}/attachments", %{})
    assert json_response(none, 422)
    assert Attachments.list(mine.id) == []
  end
end
