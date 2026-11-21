defmodule Wardmast.Test.CaptureMarkerPlug do
  @moduledoc "A tiny app for the fixture-marker probe tests: `/health` says `data: fixture`."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/health"} = conn, _opts),
    do: send_resp(conn, 200, "ok data: fixture SECRET-BODY")

  # A JSON marker endpoint (the design's example config), and one whose JSON body is cut off.
  def call(%{request_path: "/health.json"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"data":"fixture"}))
  end

  def call(%{request_path: "/health-long.json"} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"data":"fixture","pad":") <> String.duplicate("x", 200_000) <> ~s("}))
  end

  def call(conn, _opts), do: send_resp(conn, 404, "nope")
end
