defmodule Wardmast.Agents.CliDetectionTest do
  # Stub binaries only: the suite never runs a real agent CLI.
  use ExUnit.Case, async: true

  alias Wardmast.Agents.CliDetection

  @moduletag :linux

  setup do
    dir = Path.join(System.tmp_dir!(), "cd#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # The test config turns `--version` probing off; these tests use stub binaries.
  defp detect(p, opts), do: CliDetection.detect(p, [probe: true] ++ opts)
  defp detect_all(opts), do: CliDetection.detect_all([probe: true] ++ opts)
  defp gate(p, opts), do: CliDetection.gate(p, [probe: true] ++ opts)

  defp stub(dir, name, output, exit_code \\ 0) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\necho '#{output}'\nexit #{exit_code}\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "detect/2" do
    test "installed and current: reports path and version", %{dir: dir} do
      path = stub(dir, "claude", "2.3.4 (Claude Code)")
      d = detect("claude", path: dir, min_versions: %{"claude" => "2.0.0"})

      assert d.provider == "claude"
      assert d.status == :ok
      assert d.path == path
      assert d.version == "2.3.4"
      assert d.min_version == "2.0.0"
      assert d.action == nil
    end

    test "missing: no path, install step offered", %{dir: dir} do
      d = detect("codex", path: dir)

      assert d.status == :missing
      assert d.path == nil
      assert d.version == nil
      assert d.action == :install
      assert d.install_command =~ "@openai/codex"
      assert d.detail =~ "not installed"
    end

    test "below the minimum: outdated, flagged with the required version", %{dir: dir} do
      stub(dir, "claude", "1.0.9")
      d = detect("claude", path: dir, min_versions: %{"claude" => "2.0.0"})

      assert d.status == :outdated
      assert d.version == "1.0.9"
      assert d.action == :upgrade
      assert d.upgrade_command =~ "claude"
      assert d.detail =~ "1.0.9"
      assert d.detail =~ "2.0.0"
    end

    test "an unparseable --version answer is :unknown_version, not outdated", %{dir: dir} do
      stub(dir, "codex", "no digits here")
      d = detect("codex", path: dir, min_versions: %{"codex" => "0.100.0"})

      assert d.status == :unknown_version
      assert d.path == Path.join(dir, "codex")
      assert d.version == nil
    end

    test "antigravity resolves agy first, then gemini, with per-binary minimums", %{dir: dir} do
      stub(dir, "gemini", "0.30.0")
      d = detect("antigravity", path: dir)
      assert d.binary == "gemini"
      assert d.status == :outdated

      stub(dir, "agy", "1.5.9")
      d = detect("agy", path: dir)
      assert d.binary == "agy"
      assert d.version == "1.5.9"
      assert d.status == :ok
    end

    test "a minimal PATH that lacks the CLI's dir reports it missing", %{dir: dir} do
      stub(dir, "claude", "2.3.4")
      assert detect("claude", path: "/usr/bin:/bin").status == :missing
      assert detect("claude", path: "/usr/bin:/bin:" <> dir).status == :ok
    end
  end

  describe "detect_all/1" do
    test "covers claude, codex and antigravity in order", %{dir: dir} do
      rows = detect_all(path: dir)
      assert Enum.map(rows, & &1.provider) == ["claude", "codex", "antigravity"]
    end
  end

  describe "gate/2" do
    test "refuses an outdated CLI with a clear reason", %{dir: dir} do
      stub(dir, "claude", "1.0.9")

      assert {:error, {:cli_version, "claude", phrase}} =
               gate("claude",
                 enforce: true,
                 path: dir,
                 min_versions: %{"claude" => "2.0.0"}
               )

      assert phrase =~ "1.0.9"
      assert phrase =~ "2.0.0"
      assert phrase =~ "upgrade"
    end

    test "passes a current CLI, a missing one (preflight's job) and an unknown version", %{
      dir: dir
    } do
      stub(dir, "claude", "2.3.4")
      stub(dir, "codex", "mystery")

      opts = [enforce: true, path: dir, min_versions: %{"claude" => "2.0.0", "codex" => "0.1.0"}]
      assert :ok = gate("claude", opts)
      assert :ok = gate("codex", opts)
      assert :ok = gate("antigravity", opts)
    end

    test "is a no-op when enforcement is off", %{dir: dir} do
      stub(dir, "claude", "1.0.9")

      assert :ok =
               gate("claude",
                 enforce: false,
                 path: dir,
                 min_versions: %{"claude" => "2.0.0"}
               )
    end

    test "a provider with no detection spec is never refused" do
      assert :ok = gate("grok", enforce: true)
    end
  end

  describe "compare/2" do
    test "compares dotted versions numerically" do
      assert CliDetection.at_least?("0.153.4", "0.100.0")
      refute CliDetection.at_least?("0.99.0", "0.100.0")
      assert CliDetection.at_least?("2.0", "2.0.0")
      assert CliDetection.at_least?("2.1.0-beta.1", "2.0.0")
    end
  end
end
