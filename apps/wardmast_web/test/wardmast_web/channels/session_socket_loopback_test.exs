defmodule WardmastWeb.SessionSocketLoopbackTest do
  @moduledoc "The `/session` socket honours the dashboard's loopback grant (#1606)."
  use WardmastWeb.ConnCase, async: false

  alias WardmastWeb.DashboardAuth.Default
  alias WardmastWeb.SessionSocket

  require Phoenix.ChannelTest
  @endpoint WardmastWeb.Endpoint

  setup do
    previous = Application.get_env(:wardmast_web, :dashboard_trust_loopback)
    Application.put_env(:wardmast_web, :dashboard_trust_loopback, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:wardmast_web, :dashboard_trust_loopback),
        else: Application.put_env(:wardmast_web, :dashboard_trust_loopback, previous)
    end)
  end

  defp info(overrides \\ %{}) do
    Map.merge(
      %{
        peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
        x_headers: [],
        uri: %URI{host: "127.0.0.1", port: 4848},
        session: Default.grant_session("loopback", "loopback")
      },
      overrides
    )
  end

  defp connect(info), do: Phoenix.ChannelTest.connect(SessionSocket, %{}, connect_info: info)

  test "loopback peer, loopback Host, loopback marker is authorized" do
    assert {:ok, _} = connect(info())
  end

  test "proxy headers refuse the marker" do
    assert :error = connect(info(%{x_headers: [{"x-forwarded-for", "100.64.0.1"}]}))
  end

  test "a non-loopback Host refuses the marker" do
    assert :error = connect(info(%{uri: %URI{host: "evil.example", port: 4848}}))
  end

  test "a non-loopback peer refuses the marker" do
    peer = %{address: {10, 0, 0, 5}, port: 1, ssl_cert: nil}
    assert :error = connect(info(%{peer_data: peer}))
  end

  test "trust off refuses the marker" do
    Application.put_env(:wardmast_web, :dashboard_trust_loopback, false)
    assert :error = connect(info())
  end

  test "missing x_headers/uri (old connect_info) refuses the marker" do
    assert :error = connect(Map.drop(info(), [:x_headers, :uri]))
  end

  test "a bridged connection is refused even with a valid marker" do
    alias Wardmast.Worker.Egress.BridgeIdentity
    run_id = "run-#{System.unique_integer([:positive])}"
    peer = %{address: {127, 0, 0, 1}, port: 54_321, ssl_cert: nil}
    pid = start_supervised!({Agent, fn -> :ok end})
    :ok = BridgeIdentity.register(run_id, {peer.address, peer.port}, pid)
    on_exit(fn -> BridgeIdentity.delete_run(run_id) end)

    assert :error = connect(info(%{peer_data: peer}))
  end

  test "the /session endpoint socket requests :x_headers and :uri" do
    {"/session", SessionSocket, opts} =
      Enum.find(WardmastWeb.Endpoint.__sockets__(), &match?({"/session", _, _}, &1))

    ci = opts[:websocket][:connect_info]
    assert :x_headers in ci
    assert :uri in ci
  end
end
