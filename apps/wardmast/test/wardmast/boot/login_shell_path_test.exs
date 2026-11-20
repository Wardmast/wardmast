defmodule Wardmast.Boot.LoginShellPathTest do
  # Sync: `apply/1` with the real env mutates the VM's PATH (saved and restored).
  use ExUnit.Case, async: false

  alias Wardmast.Agents.CliDetection
  alias Wardmast.Boot.LoginShellPath
  alias Wardmast.Worker.SpawnEnv

  @moduletag :linux

  @launchd_path "/usr/bin:/bin:/usr/sbin:/sbin"

  setup do
    dir = Path.join(System.tmp_dir!(), "ls#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A login-shell stand-in: ignores its `-l -i -c <script>` argv and answers with
  # the PATH the operator's rc files would have built, after some rc noise.
  defp shell(dir, login_path, opts \\ []) do
    path = Path.join(dir, Keyword.get(opts, :name, "fakesh"))

    body =
      Keyword.get(opts, :body) ||
        "printf 'motd noise\\n'\nprintf '__WARDMAST_PATH_START__#{login_path}__WARDMAST_PATH_END__'\n"

    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp fake_cli(dir, name, version) do
    bin = Path.join(dir, "loginbin")
    File.mkdir_p!(bin)
    exe = Path.join(bin, name)
    File.write!(exe, "#!/bin/sh\necho '#{version}'\n")
    File.chmod!(exe, 0o755)
    bin
  end

  describe "minimal?/1" do
    test "the launchd / desktop default PATH is minimal" do
      assert LoginShellPath.minimal?(@launchd_path)
      assert LoginShellPath.minimal?("/usr/bin:/bin")
      assert LoginShellPath.minimal?("")
      assert LoginShellPath.minimal?(nil)
    end

    test "a PATH with any user or package-manager dir is not" do
      refute LoginShellPath.minimal?(@launchd_path <> ":/opt/homebrew/bin")
      refute LoginShellPath.minimal?("/home/u/.local/bin:/usr/bin")
    end
  end

  describe "resolve/2" do
    test "extracts the PATH between the markers, ignoring rc noise", %{dir: dir} do
      sh = shell(dir, "/opt/stub/bin:/usr/bin")
      assert {:ok, "/opt/stub/bin:/usr/bin"} = LoginShellPath.resolve(sh, 5_000)
    end

    test "a shell that never answers times out", %{dir: dir} do
      sh = shell(dir, "", body: "exec sleep 5\n")
      assert {:error, :timeout} = LoginShellPath.resolve(sh, 150)
    end

    test "a shell that answers without the markers is an error", %{dir: dir} do
      sh = shell(dir, "", body: "echo hello\n")
      assert {:error, :no_path_in_output} = LoginShellPath.resolve(sh, 5_000)
    end

    test "a shell that exits non-zero is an error", %{dir: dir} do
      sh = shell(dir, "", body: "exit 3\n")
      assert {:error, {:exit, 3}} = LoginShellPath.resolve(sh, 5_000)
    end

    test "a missing shell is an error" do
      assert {:error, :no_shell} = LoginShellPath.resolve("/nonexistent/sh", 5_000)
    end
  end

  describe "run/1 (injected env)" do
    test "a minimal PATH is replaced by the login shell's, current dirs kept after", %{dir: dir} do
      sh = shell(dir, "/opt/stub/bin:/usr/bin:/bin")
      test_pid = self()

      assert {:applied, info} =
               LoginShellPath.run(
                 enabled: true,
                 path: @launchd_path,
                 shell: sh,
                 put_env: fn path -> send(test_pid, {:put_path, path}) end
               )

      assert_received {:put_path, path}
      assert path == "/opt/stub/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      assert info.source == :login_shell
      assert info.shell == sh
      assert info.added == ["/opt/stub/bin"]
    end

    test "an already-rich PATH is left alone and the shell is not run", %{dir: dir} do
      sh = shell(dir, "", body: "echo ran > #{dir}/ran\nexit 1\n")

      assert {:skipped, :path_not_minimal} =
               LoginShellPath.run(
                 enabled: true,
                 path: @launchd_path <> ":/opt/homebrew/bin",
                 shell: sh,
                 put_env: fn _ -> flunk("must not set PATH") end
               )

      refute File.exists?(Path.join(dir, "ran"))
    end

    test "a failing shell leaves PATH untouched and records why", %{dir: dir} do
      sh = shell(dir, "", body: "exit 1\n")

      assert {:skipped, {:resolve_failed, {:exit, 1}}} =
               LoginShellPath.run(
                 enabled: true,
                 path: @launchd_path,
                 shell: sh,
                 put_env: fn _ -> flunk("must not set PATH") end
               )
    end

    test "disabled is a no-op" do
      assert {:skipped, :disabled} =
               LoginShellPath.run(enabled: false, path: @launchd_path, shell: "/bin/true")
    end

    test "no shell to ask is a skip" do
      assert {:skipped, :no_shell} =
               LoginShellPath.run(enabled: true, path: @launchd_path, shell: nil)
    end
  end

  describe "GUI launch end to end (simulated minimal PATH)" do
    test "CLI detection and the spawn env see the login shell's PATH", %{dir: dir} do
      bin = fake_cli(dir, "claude", "2.4.0")
      sh = shell(dir, bin <> ":/usr/bin:/bin")

      original = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", original) end)
      System.put_env("PATH", @launchd_path)

      # Before boot resolution the GUI-launched server cannot see claude.
      assert CliDetection.detect("claude", probe: false).status == :missing
      assert System.find_executable("claude") == nil

      assert {:applied, _} = LoginShellPath.run(enabled: true, shell: sh)

      # CLI detection (default PATH) and the BEAM's own lookup agree...
      assert %{status: :ok, version: "2.4.0"} =
               CliDetection.detect("claude", probe: true, min_versions: %{"claude" => "2.0.0"})

      assert System.find_executable("claude") == Path.join(bin, "claude")

      # ...and so does the env a worker is spawned with: PATH is on the spawn
      # allowlist, so a worker inherits the server's (now resolved) PATH.
      assert SpawnEnv.allowed?("PATH")
      refute {"PATH", false} in SpawnEnv.port_env([], "claude")
      assert String.contains?(System.get_env("PATH"), bin)
      assert LoginShellPath.info().source == :login_shell
    end
  end
end
