defmodule WardmastWeb.Api.SupportBundleController do
  @moduledoc """
  `GET /api/support/bundle` — the diagnostics bundle as
  `{"filename", "data_base64"}` for `arb support bundle`. `:operator` in
  `WardmastWeb.ApiPolicy`.
  """
  use WardmastWeb, :controller

  def show(conn, _params) do
    case Wardmast.Support.Bundle.build() do
      {:ok, %{filename: filename, data: data}} ->
        json(conn, %{filename: filename, data_base64: Base.encode64(data)})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "bundle_failed", detail: inspect(reason)})
    end
  end
end
