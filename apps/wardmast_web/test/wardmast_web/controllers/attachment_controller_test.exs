defmodule WardmastWeb.AttachmentControllerTest do
  @moduledoc """
  `GET /attachments/:id` (bd-5hlegn) serves stored bytes to the dashboard origin, so
  only verified raster images go out inline, and every response is locked down.
  """
  use WardmastWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

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
      Ash.create(Workspace, %{
        name: "att-ctl-#{System.unique_integer([:positive])}",
        prefix: "act"
      })

    {:ok, issue} = Ash.create(Issue, %{title: "pictures", workspace_id: ws.id})

    {:ok, att} =
      Attachments.create(issue, %{data: Fixture.png(8, 6, salt: "x")}, source: "worker")

    {:ok, conn: dashboard_login(build_conn()), att: att, dir: dir}
  end

  defp blob_path(dir, att), do: Path.wildcard(Path.join([dir, "**", "#{att.sha256}.*"])) |> hd()

  defp assert_locked_down(conn) do
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-security-policy") ==
             ["default-src 'none'; img-src 'self'; sandbox"]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^(inline|attachment)/
  end

  test "a real png is served inline with the lock-down headers", %{conn: conn, att: att} do
    conn = get(conn, ~p"/attachments/#{att.id}")

    assert response(conn, 200)
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "image/png"
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert_locked_down(conn)
  end

  test "html bytes behind a png record are never served", %{conn: conn, att: att, dir: dir} do
    File.write!(blob_path(dir, att), "<html><script>alert(1)</script></html>")

    conn = get(conn, ~p"/attachments/#{att.id}")

    assert conn.status == 415
    refute response(conn, 415) =~ "<script>"
    assert [type] = get_resp_header(conn, "content-type")
    refute type =~ "html"
    assert_locked_down(conn)
    assert get_resp_header(conn, "content-disposition") != ["inline"]
  end

  test "svg bytes behind a png record are never served", %{conn: conn, att: att, dir: dir} do
    File.write!(blob_path(dir, att), ~s(<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>))

    conn = get(conn, ~p"/attachments/#{att.id}")

    assert conn.status == 415
    assert_locked_down(conn)
  end

  test "a record whose stored type is not an allowlisted raster is refused", ctx do
    %{conn: conn, att: att} = ctx

    for type <- ["text/html", "image/svg+xml"] do
      {1, _} =
        Repo.update_all(
          from(a in Attachments.Attachment, where: a.id == ^att.id),
          set: [content_type: type]
        )

      conn = get(conn, ~p"/attachments/#{att.id}")
      assert conn.status == 415
      assert [ct] = get_resp_header(conn, "content-type")
      refute ct =~ "html"
      refute ct =~ "svg"
      assert_locked_down(conn)
    end
  end

  test "a stored type that disagrees with the sniffed bytes is refused", ctx do
    %{conn: conn, att: att, dir: dir} = ctx
    # The record says jpeg, the blob (moved to where a jpeg lives) is a png.
    png = blob_path(dir, att)
    File.rename!(png, Path.rootname(png) <> ".jpg")

    {1, _} =
      Repo.update_all(
        from(a in Attachments.Attachment, where: a.id == ^att.id),
        set: [content_type: "image/jpeg"]
      )

    conn = get(conn, ~p"/attachments/#{att.id}")
    assert conn.status == 415
  end

  test "errors carry the lock-down headers too", %{conn: conn} do
    conn = get(conn, ~p"/attachments/#{Ecto.UUID.generate()}")
    assert conn.status == 404
    assert_locked_down(conn)
  end
end
