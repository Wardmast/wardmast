defmodule WardmastWeb.AttachmentController do
  @moduledoc """
  Serves a ticket attachment's bytes to the dashboard (`GET /attachments/:id`,
  bd-5hlegn; `docs/design/ui-screenshot-capture.md` §10).

  Behind the dashboard gate like every page. The stored bytes are an image of a
  type the store sniffed on the way in, but they came from a worker, so they are
  served as inert as possible: `Content-Type` from the stored type,
  `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox`, so
  nothing a worker stored can run as a page in this origin. A blob that retention
  deleted is `410 Gone`; the API and MCP return metadata and this URL, never bytes.
  """

  use WardmastWeb, :controller

  alias Wardmast.Attachments

  def show(conn, %{"id" => id}) do
    with %Attachments.Attachment{} = att <- Attachments.get(id),
         {:ok, data} <- Attachments.read_blob(att) do
      conn
      |> put_resp_content_type(att.content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox")
      |> put_resp_header("cache-control", "private, max-age=3600, immutable")
      |> send_resp(200, data)
    else
      nil -> send_plain(conn, 404, "no such attachment")
      {:error, :pruned} -> send_plain(conn, 410, "this attachment was pruned by retention")
      {:error, :missing} -> send_plain(conn, 410, "the attachment's file is gone")
    end
  end

  defp send_plain(conn, status, message) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, message)
  end
end
