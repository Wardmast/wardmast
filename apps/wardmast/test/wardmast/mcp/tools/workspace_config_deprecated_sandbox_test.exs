defmodule Wardmast.MCP.Tools.WorkspaceConfigDeprecatedSandboxTest do
  @moduledoc """
  bd-4j0nfe: the root `sandbox.*` keys are a deprecated alias of
  `agent.security.sandbox.*`. `workspace_config_get` reads the canonical key and
  `workspace_config_set` writes it, each saying so in `warnings`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cfg-sb-#{System.unique_integer([:positive])}",
        prefix: "sb#{:rand.uniform(99_999)}",
        config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "bwrap"}}}}
      })

    {:ok,
     ws: ws, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  test "get sandbox.backend reads the canonical key and warns", %{coordinator: scope} do
    assert {:ok, data} = Tools.workspace_config_get(scope, %{"key" => "sandbox.backend"})

    assert data.value == "bwrap"
    assert data.key == "agent.security.sandbox.backend"
    assert [warning] = data.warnings

    assert warning ==
             "`sandbox.backend` is deprecated; using `agent.security.sandbox.backend` " <>
               "instead (the key the sandbox is read from)"
  end

  test "get on a canonical key carries no warnings", %{coordinator: scope} do
    assert {:ok, data} =
             Tools.workspace_config_get(scope, %{"key" => "agent.security.sandbox.backend"})

    assert data.value == "bwrap"
    refute Map.has_key?(data, :warnings)
  end

  @tag capture_log: true
  test "set sandbox.backend writes the canonical key and warns", %{coordinator: scope, ws: ws} do
    assert {:ok, data} =
             Tools.workspace_config_set(scope, %{"key" => "sandbox.backend", "value" => "auto"})

    assert [warning] = data.warnings
    assert warning =~ "`sandbox.backend` is deprecated"
    assert warning =~ "agent.security.sandbox.backend"

    config = Ash.get!(Workspace, ws.id).config
    refute Map.has_key?(config, "sandbox")
    assert get_in(config, ["agent", "security", "sandbox", "backend"]) == "auto"
  end
end
