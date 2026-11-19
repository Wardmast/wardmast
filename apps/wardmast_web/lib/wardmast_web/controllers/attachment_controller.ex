defmodule WardmastWeb.AttachmentController do
  @moduledoc """
  Serves a ticket attachment's bytes to the dashboard (`GET /attachments/:id`,
  bd-5hlegn; `docs/design/ui-screenshot-capture.md` §10).

  Behind the dashboard gate like every page. The bytes came from a worker, so
  they are treated as hostile and served only when provably a raster image:

    * the stored type must be on the allowlist (`image/png`, `image/jpeg`,
      `image/webp`; the store refuses anything else, GIF included, at upload);
    * the bytes are re-sniffed by magic number and must agree with the stored
      type. Anything else (HTML, SVG, a mismatched blob) is `415`, never inline,
      and the response body is a fixed plain-text message, not the bytes;
    * every response, errors included, carries `X-Content-Type-Options: nosniff`,
      `Content-Security-Policy: default-src 'none'; img-src 'self'; sandbox` and
      an explicit `Content-Disposition` (`inline` only for a verified raster).

  The `Content-Type` is chosen from literals in `serve_image/3`, never copied from
  the record. A blob that retention deleted is `410 Gone`; the API and MCP return
  metadata and this URL, never bytes.
  """

  use WardmastWeb, :controller

  alias Wardmast.Attachments
  alias Wardmast.Attachments.Image

  plug :lock_down

  def show(conn, %{"id" => id}) do
    with %Attachments.Attachment{} = att <- Attachments.get(id),
         :ok <- check_type(att.content_type),
         {:ok, data} <- Attachments.read_blob(att),
         :ok <- check_bytes(data, att.content_type) do
      serve_image(conn, att.content_type, data)
    else
      nil -> send_plain(conn, 404, "no such attachment")
      {:error, :pruned} -> send_plain(conn, 410, "this attachment was pruned by retention")
      {:error, :missing} -> send_plain(conn, 410, "the attachment's file is gone")
      {:error, :unsupported} -> send_plain(conn, 415, "not a servable image type")
    end
  end

  # Applied to every response. `attachment` is the safe default; a verified
  # raster overrides it with `inline` in `serve_image/3`.
  defp lock_down(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; img-src 'self'; sandbox")
    |> put_resp_header("content-disposition", "attachment")
  end

  defp check_type(type) do
    if type in Image.types(), do: :ok, else: {:error, :unsupported}
  end

  # The bytes must sniff as the very type the record claims.
  defp check_bytes(data, type) do
    case Image.inspect_binary(data) do
      {:ok, %{type: ^type}} -> :ok
      _ -> {:error, :unsupported}
    end
  end

  # The content type is a literal per clause, never the record's string.
  defp serve_image(conn, "image/png", data),
    do: conn |> put_resp_content_type("image/png", nil) |> send_image(data)

  defp serve_image(conn, "image/jpeg", data),
    do: conn |> put_resp_content_type("image/jpeg", nil) |> send_image(data)

  defp serve_image(conn, "image/webp", data),
    do: conn |> put_resp_content_type("image/webp", nil) |> send_image(data)

  # The only place image bytes leave. `data` was verified against its type by magic
  # number in `check_bytes/2`, so what is sent is a raster image served `nosniff`
  # under a sandboxing CSP, not attacker markup. Sobelow cannot see that validation,
  # hence this narrow skip on XSS.SendResp only (XSS.ContentType is not skipped).
  # sobelow_skip ["XSS.SendResp"]
  defp send_image(conn, data) do
    conn
    |> put_resp_header("content-disposition", "inline")
    |> put_resp_header("cache-control", "private, max-age=3600, immutable")
    |> send_resp(200, data)
  end

  defp send_plain(conn, status, message) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, message)
  end
end
