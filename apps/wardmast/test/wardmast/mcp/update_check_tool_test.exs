defmodule Wardmast.MCP.UpdateCheckToolTest do
  use ExUnit.Case, async: false

  alias Wardmast.MCP.{Catalog, Scope, Tools}
  alias Wardmast.Release.UpdateCheck

  @coordinator %Scope{tier: :coordinator, workspace_id: "w"}

  test "is a coordinator-only catalog tool" do
    assert {:ok, tool} = Catalog.fetch("update_check")
    assert tool.tiers == [:coordinator]
  end

  test "returns the same map as the shared backend, with the rate-limit flag" do
    Req.Test.stub(
      :update_check_tool,
      &Req.Test.json(&1, %{"tag_name" => "v99.0.0", "html_url" => "u"})
    )

    pid =
      start_supervised!(
        {UpdateCheck,
         enabled: true,
         repo: "acme/arbiter",
         running_version: "0.2.0",
         initial_delay_ms: :infinity,
         req_options: [plug: {Req.Test, :update_check_tool}]}
      )

    Req.Test.allow(:update_check_tool, self(), pid)

    assert {:ok, first} = Tools.update_check(@coordinator, %{})

    assert %{
             latest: "v99.0.0",
             update_available: true,
             release_url: "u",
             cached: false,
             error: nil
           } =
             first

    assert is_binary(first.running) and is_binary(first.checked_at)
    assert {:ok, %{cached: true, latest: "v99.0.0"}} = Tools.update_check(@coordinator, %{})
  end

  test "reports an error when the checker is disabled" do
    assert {:ok, %{error: error, cached: true}} = Tools.update_check(@coordinator, %{})
    assert is_binary(error)
  end
end
