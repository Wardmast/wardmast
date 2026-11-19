defmodule WardmastWeb.TaskDetailAttachmentsTest do
  @moduledoc "The ATTACHMENTS panel of a ticket page (bd-5hlegn): images, with before/after pairs side by side."
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WardmastWeb.TaskDetailLiveHelpers

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
  alias Wardmast.Repo
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

    {:ok, ws} =
      Ash.create(Workspace, %{name: "att-ui-#{System.unique_integer([:positive])}", prefix: "aui"})

    {:ok, issue} = Ash.create(Issue, %{title: "has pictures", workspace_id: ws.id})
    {:ok, ws: ws, issue: issue, conn: dashboard_login(build_conn())}
  end

  defp attach(issue, salt, attrs \\ %{}) do
    {:ok, att} =
      Attachments.create(issue, Map.put(attrs, :data, Fixture.png(8, 6, salt: salt)),
        source: "worker"
      )

    att
  end

  test "no panel for a ticket with no attachments", %{conn: conn, issue: issue} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")
    refute has_element?(view, "#panel-attachments")
  end

  test "a before/after pair renders side by side, a lone image on its own", ctx do
    %{conn: conn, issue: issue} = ctx
    before_att = attach(issue, "1", %{role: "before", shot_id: "home", caption: "Old home"})
    after_att = attach(issue, "2", %{role: "after", shot_id: "home", caption: "New home"})
    loose = attach(issue, "3", %{caption: "A mock"})
    lonely = attach(issue, "4", %{role: "after", shot_id: "orphan"})

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")

    assert has_element?(view, "#panel-attachments")

    # One pair, holding both images in before / after order.
    assert has_element?(
             view,
             "#attachment-pair-home [data-role=before] img[src='/attachments/#{before_att.id}']"
           )

    assert has_element?(
             view,
             "#attachment-pair-home [data-role=after] img[src='/attachments/#{after_att.id}']"
           )

    assert has_element?(view, "#attachment-pair-home[data-layout=side-by-side]")

    # The pair's images are not also rendered as loose tiles.
    refute has_element?(view, "#attachment-#{before_att.id}")
    refute has_element?(view, "#attachment-#{after_att.id}")

    # Loose images, including an `after` with no `before`, are single tiles.
    assert has_element?(view, "#attachment-#{loose.id} img[src='/attachments/#{loose.id}']")
    assert has_element?(view, "#attachment-#{lonely.id} img")
    refute has_element?(view, "#attachment-#{lonely.id}[data-pair]")
  end

  test "a pruned attachment shows a placeholder, not a broken image", %{conn: conn, issue: issue} do
    att = attach(issue, "p", %{caption: "gone soon"})
    prune!(att)

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")

    assert has_element?(view, "#attachment-#{att.id}[data-pruned] ")
    refute has_element?(view, "#attachment-#{att.id} img")
  end

  describe "GET /attachments/:id" do
    test "serves the bytes with nosniff and a sandboxing CSP", %{conn: conn, issue: issue} do
      data = Fixture.png(8, 6, salt: "serve")
      {:ok, att} = Attachments.create(issue, %{data: data}, source: "worker")

      conn = get(conn, ~p"/attachments/#{att.id}")

      assert response(conn, 200) == data
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
    end

    test "needs a dashboard login", %{issue: issue} do
      att = attach(issue, "auth")
      conn = get(build_conn(), ~p"/attachments/#{att.id}")
      assert conn.status in [302, 401, 403]
    end

    test "a pruned attachment is 410, an unknown id 404", %{conn: conn, issue: issue} do
      att = attach(issue, "gone")

      prune!(att)

      assert conn |> get(~p"/attachments/#{att.id}") |> response(410)
      assert conn |> get(~p"/attachments/#{Ecto.UUID.generate()}") |> response(404)
      assert conn |> get("/attachments/not-a-uuid") |> response(404)
    end
  end

  # What the retention sweep does to a row: the blob goes, `pruned_at` is set.
  defp prune!(att) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE ticket_attachments SET pruned_at = ? WHERE id = ?",
      [DateTime.to_iso8601(DateTime.utc_now()), att.id]
    )
  end
end
