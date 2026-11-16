defmodule Wardmast.LegacyModuleNameTest do
  use ExUnit.Case, async: true

  alias Wardmast.LegacyModuleName

  test "rewrites module names persisted before the Arbiter -> Wardmast rename" do
    assert LegacyModuleName.normalize("Arbiter.Workflow.Work") == "Wardmast.Workflow.Work"

    assert LegacyModuleName.normalize("Elixir.Arbiter.Mergers.Github") ==
             "Elixir.Wardmast.Mergers.Github"

    assert LegacyModuleName.normalize("Elixir.ArbiterWeb.Endpoint") ==
             "Elixir.WardmastWeb.Endpoint"
  end

  test "leaves current and foreign names alone" do
    assert LegacyModuleName.normalize("Wardmast.Workflow.Work") == "Wardmast.Workflow.Work"

    assert LegacyModuleName.normalize("Elixir.MyApp.Arbiter.Thing") ==
             "Elixir.MyApp.Arbiter.Thing"

    assert LegacyModuleName.normalize("ArbiterProFake") == "ArbiterProFake"
  end

  test "passes non-binaries through" do
    assert LegacyModuleName.normalize(nil) == nil
  end

  test "a workflow row persisted under the old name still loads" do
    assert {:ok, Wardmast.Workflow.Example.GreetThenWave} =
             Wardmast.Workflows.Machine.load_workflow_module(
               "Arbiter.Workflow.Example.GreetThenWave"
             )
  end
end
