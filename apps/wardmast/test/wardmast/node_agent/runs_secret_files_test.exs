defmodule Wardmast.NodeAgent.RunsSecretFilesTest do
  @moduledoc """
  bd-b2t0kw: `secret_files` (agy's service-account key and MCP config) have a delivery
  path in a cluster pod only (`/boot` -> the pod's memory volume). A machine node has no
  tmpfs layout for them yet, so it refuses such a spec at `assign` instead of starting a
  run that would be missing its credential. Placement never sends one there (agy needs
  `caps.agy`, which only a cluster controller advertises); this is the guard behind it.
  """
  use ExUnit.Case, async: true

  alias Wardmast.NodeAgent.Runs

  defp spec(extra) do
    Map.merge(
      %{
        "version" => 1,
        "run" => "run-sf-1",
        "name" => "arb-bd-sf-1234",
        "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/work/tree"},
          %{"kind" => "config_dir", "path" => "/work/home/.gemini"}
        ],
        "command" => ["/opt/arbiter/cli/agy", "-p", "x"]
      },
      extra
    )
  end

  test "a machine node refuses a spec that carries secret_files, before starting anything" do
    files = %{"agy-adc.json" => %{"content" => Base.encode64(~s({"private_key":"PK"}))}}

    assert {:error, {:refused, {:unsupported, "secret_files"}}} =
             Runs.assign(spec(%{"secret_files" => files}), [])
  end
end
