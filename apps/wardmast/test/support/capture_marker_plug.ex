defmodule Wardmast.Test.CaptureMarkerPlug do
  @moduledoc "A tiny app for the fixture-marker probe tests: `/health` says `data: fixture`."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/health"} = conn, _opts),
    do: send_resp(conn, 200, "ok data: fixture SECRET-BODY")

  def call(conn, _opts), do: send_resp(conn, 404, "nope")
end
