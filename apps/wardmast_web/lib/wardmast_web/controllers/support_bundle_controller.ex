defmodule WardmastWeb.SupportBundleController do
  @moduledoc """
  Diagnostics bundle (`Wardmast.Support.Bundle`): `GET /support/bundle` serves
  the redacted `.tar.gz` to a dashboard login (the About page's button).
  """
  use WardmastWeb, :controller

  def show(conn, _params) do
    case Wardmast.Support.Bundle.build() do
      {:ok, %{filename: filename, data: data}} ->
        conn
        |> put_resp_content_type("application/gzip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, data)

      {:error, reason} ->
        conn |> put_status(500) |> text("could not build bundle: #{inspect(reason)}")
    end
  end
end
