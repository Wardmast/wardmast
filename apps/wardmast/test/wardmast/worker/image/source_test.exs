defmodule Wardmast.Worker.Image.SourceTest do
  @moduledoc """
  SI4 (`docs/design/remote-workers.md` §21.2.1, §21.6) and SI13: the per-run choice of
  image source. A machine node pulls the published image when it lists `registry` in
  `caps.image_sources` and the repo's registry has a pull credential that node may hold;
  a cluster takes the registry image; anything else is refused (there is no build
  fallback).
  """
  use ExUnit.Case, async: true

  alias Wardmast.NodeAgent.PullAuth
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.Image.Source

  @install %{
    registry: "install.example.com/arb",
    username: "pusher",
    password: "PUSH-install",
    pull_username: "reader",
    pull_password: "PULL-install"
  }

  defp machine(
         caps \\ %{"image" => "registry", "image_sources" => ["registry"]},
         pins \\ []
       ),
       do: %{id: "n1", name: "oryx", kind: :machine, labels: [], workspace_ids: pins, caps: caps}

  defp cluster, do: %{id: "c1", name: "k3s", kind: :cluster, caps: %{"image" => "registry"}}

  defp ctx(workspace \\ %Workspace{id: "ws-1", config: %{}}),
    do: %{workspace: workspace, repo: "vstim"}

  defp opts(extra \\ []), do: Keyword.merge([config: @install, workspaces: []], extra)

  test "a cluster (caps.image = registry, no image_sources) takes the registry image" do
    assert Source.choose(cluster(), ctx(), opts()) == :registry
    assert Source.registry_only?(cluster())
    assert Source.node_source(cluster()) == "registry"
  end

  test "a machine that lists registry and may hold a credential pulls" do
    assert {:pull, %{auth: %PullAuth{registry: "install.example.com"}, level: :install}} =
             Source.choose(machine(), ctx(), opts())

    assert Source.node_source(machine()) == "registry"
  end

  test "an agent that does not list registry (an older agent) is refused" do
    for caps <- [%{"image" => "build"}, %{}, %{"image_sources" => ["build"]}] do
      assert Source.choose(machine(caps), ctx(), opts()) == {:error, :node_cannot_pull}
      assert Source.node_source(machine(caps)) == "build"
    end
  end

  test "no pull credential, or one out of the node's reach, is refused" do
    no_pull = Map.drop(@install, [:pull_username, :pull_password])
    assert {:error, _} = Source.choose(machine(), ctx(), opts(config: no_pull))

    pinned = machine(%{"image_sources" => ["registry"]}, ["ws-1"])
    assert {:error, _} = Source.choose(pinned, ctx(), opts())
  end
end
