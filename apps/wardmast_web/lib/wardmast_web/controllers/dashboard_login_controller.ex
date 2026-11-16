defmodule WardmastWeb.DashboardLoginController do
  @moduledoc """
  The login page for `WardmastWeb.DashboardAuth.Default` (bd-3gycsz).

  `GET /login?token=…` only *renders a confirmation form*; redeeming happens on
  `POST /login`, so a link previewer or prefetch that fetches the URL cannot
  burn the one-time token.
  """
  use WardmastWeb, :controller

  alias WardmastWeb.DashboardAuth.Default
  alias WardmastWeb.DashboardAuth.LoginTokens

  def show(conn, params) do
    token = if is_binary(params["token"]), do: params["token"], else: nil
    render(conn, :show, token: token, layout: false)
  end

  def create(conn, %{"token" => token}) do
    case LoginTokens.consume(token) do
      {:ok, _} ->
        conn |> Default.put_token_grant("operator") |> redirect(to: "/")

      :error ->
        conn
        |> put_flash(:error, "That login link is invalid, expired or already used.")
        |> redirect(to: "/login")
    end
  end

  def create(conn, _params), do: redirect(conn, to: "/login")

  def delete(conn, _params), do: conn |> Default.revoke() |> redirect(to: "/login")
end
