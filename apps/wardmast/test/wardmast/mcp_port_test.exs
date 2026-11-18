defmodule Wardmast.MCPPortTest do
  # Mutates the Endpoint application env, which is global.
  use ExUnit.Case, async: false

  alias Wardmast.MCP

  test "server_url, events_url and the rendered .mcp.json honour a non-default port" do
    prev = Application.get_env(:wardmast_web, WardmastWeb.Endpoint, [])
    Application.put_env(:wardmast_web, WardmastWeb.Endpoint, Keyword.put(prev, :http, port: 5151))
    on_exit(fn -> Application.put_env(:wardmast_web, WardmastWeb.Endpoint, prev) end)

    assert MCP.server_url() == "http://127.0.0.1:5151/mcp"
    assert MCP.events_url() == "http://127.0.0.1:5151/events"

    cfg = Wardmast.MCP.AgentConfig.Claude.config_map(mcp_url: MCP.server_url(), scope_token: "t")

    assert get_in(cfg, ["mcpServers", MCP.server_name(), "url"]) == "http://127.0.0.1:5151/mcp"
  end
end
