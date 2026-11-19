defmodule Wardmast.Doctor.PlatformTest do
  use ExUnit.Case, async: true

  alias Wardmast.Doctor.Platform

  test "darwin: baseline dirs are appended to the PATH and tools resolve on it" do
    test_pid = self()

    find = fn name, path ->
      send(test_pid, {:find, name, path})
      if name == "gh", do: "/opt/homebrew/bin/gh"
    end

    report = Platform.report(os: {:unix, :darwin}, home: "/Users/x", path: "/usr/bin", find: find)

    assert report.os == "darwin"
    assert report.path == "/usr/bin:/opt/homebrew/bin:/usr/local/bin:/Users/x/.local/bin"
    assert report.tools["gh"] == "/opt/homebrew/bin/gh"
    assert report.tools["claude"] == nil
    expected = report.path
    assert_received {:find, "gtimeout", ^expected}
  end

  test "linux: the PATH is unchanged" do
    report = Platform.report(os: {:unix, :linux}, path: "/usr/bin", find: fn _, _ -> nil end)

    assert report.os == "linux"
    assert report.path == "/usr/bin"
    assert report.tools == Map.new(~w(gtimeout claude gh glab mise), &{&1, nil})
  end

  describe "provider CLI detection (bd-5wfsj7)" do
    @moduletag :linux

    setup do
      dir = Path.join(System.tmp_dir!(), "pl#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "reports each CLI's path, version and verdict from the server's PATH", %{dir: dir} do
      File.write!(Path.join(dir, "claude"), "#!/bin/sh\necho '2.2.0'\n")
      File.chmod!(Path.join(dir, "claude"), 0o755)
      File.write!(Path.join(dir, "codex"), "#!/bin/sh\necho '0.1.0'\n")
      File.chmod!(Path.join(dir, "codex"), 0o755)

      detect = fn path ->
        Wardmast.Agents.CliDetection.detect_all(path: path, probe: true)
      end

      report =
        Platform.report(
          os: {:unix, :linux},
          path: "/usr/bin:" <> dir,
          find: fn _, _ -> nil end,
          clis: detect.("/usr/bin:" <> dir)
        )

      by = Map.new(report.clis, &{&1.provider, &1})
      assert %{status: :ok, version: "2.2.0", path: path} = by["claude"]
      assert path == Path.join(dir, "claude")
      assert %{status: :outdated, version: "0.1.0"} = by["codex"]
      assert %{status: :missing} = by["antigravity"]
    end

    test "the report encodes as JSON (it is served by /api/server/platform)" do
      report = Platform.report(os: {:unix, :linux}, path: "/usr/bin", find: fn _, _ -> nil end)
      assert {:ok, json} = Jason.encode(report)
      assert %{"clis" => [_, _, _], "path_source" => %{"source" => _}} = Jason.decode!(json)
    end
  end
end
