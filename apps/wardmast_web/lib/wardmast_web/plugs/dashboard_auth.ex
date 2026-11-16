defmodule WardmastWeb.Plugs.DashboardAuth do
  @moduledoc """
  Gate for the `:browser` pipeline (bd-3gycsz). Delegates the decision to the
  configured `WardmastWeb.DashboardAuth` implementation and redirects the
  browser to its login page when it says no. Must run after `fetch_session`.

  The login routes themselves sit in a pipeline without this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case WardmastWeb.DashboardAuth.authenticate(conn) do
      {:ok, conn, identity} ->
        # bd-6i7yzq: the dashboard edge — writes this request makes are the
        # operator's.
        Wardmast.Actor.put(Wardmast.Actor.operator(identity))
        assign(conn, :dashboard_identity, identity)

      :error ->
        Wardmast.Actor.put(nil)

        conn
        |> Phoenix.Controller.redirect(to: WardmastWeb.DashboardAuth.login_path())
        |> halt()
    end
  end
end
