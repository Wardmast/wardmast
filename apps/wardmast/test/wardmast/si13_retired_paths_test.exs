defmodule Wardmast.SI13RetiredPathsTest do
  @moduledoc """
  SI13 (`docs/design/remote-workers.md` §21.6 step 6): build-from-plan for nodes, the
  CLI shelf and `/nodes/files` are gone. These guards fail if a code path comes back.
  """
  use ExUnit.Case, async: true

  alias Wardmast.NodeAgent.RunSpec
  alias Wardmast.Settings

  @root Path.expand("../../../..", __DIR__)

  test "the shelf modules are gone" do
    refute Code.ensure_loaded?(Wardmast.Nodes.Files)
    refute Code.ensure_loaded?(Wardmast.NodeAgent.Files)
  end

  test "nodes.machine_image_source is gone from settings" do
    refute function_exported?(Settings, :machine_image_source, 0)
    refute function_exported?(Settings, :machine_image_sources, 0)
    refute function_exported?(Settings, :nodes_machine_image_source, 0)
    refute "nodes.machine_image_source" in Wardmast.Settings.Registry.keys()
  end

  describe "RunSpec" do
    defp base do
      %{
        "version" => 1,
        "run" => "run-1",
        "task" => "bd-abc",
        "name" => "arb-bd-abc-1234",
        "install" => "inst1",
        "image" => %{
          "tag" => "localhost/arbiter-dev/beam:abc123",
          "ref" => "reg.example/r/worker@sha256:" <> String.duplicate("a", 64)
        },
        "cwd" => "/work/tree",
        "mounts" => [%{"kind" => "worktree", "path" => "/work/tree"}],
        "command" => ["claude", "--print"]
      }
    end

    test "a pinned ref validates" do
      assert {:ok, %RunSpec{}} = RunSpec.validate(base())
    end

    test "a plan is refused" do
      image = Map.put(base()["image"], "plan", %{"tag" => "t"})
      assert {:error, _} = RunSpec.validate(%{base() | "image" => image})
    end

    test "an image without a ref is refused" do
      image = Map.delete(base()["image"], "ref")
      assert {:error, _} = RunSpec.validate(%{base() | "image" => image})
    end

    test "the cli mount kind is refused" do
      cli = %{
        "kind" => "cli",
        "name" => "claude",
        "sha256" => String.duplicate("a", 64),
        "path" => "/opt/arbiter/cli/claude"
      }

      assert {:error, _} = RunSpec.validate(%{base() | "mounts" => [cli]})
    end
  end

  test "no lib code references the retired paths" do
    needles = [
      "Nodes.Files",
      "NodeAgent.Files",
      "remote_cli",
      "machine_image_source",
      "/nodes/files",
      "send_shelved"
    ]

    files =
      Path.wildcard(Path.join(@root, "apps/*/lib/**/*.{ex,eex,sh}")) ++
        Path.wildcard(Path.join(@root, "apps/*/priv/parity/*.exs"))

    hits =
      for f <- files, text = File.read!(f), n <- needles, String.contains?(text, n), do: {f, n}

    assert hits == []
  end
end
