defmodule WardmastCli.Supervisor.LaunchdTest do
  # async: false — Process-dictionary runner seam (Start.run_cmd).
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Supervisor
  alias WardmastCli.Supervisor.Launchd

  @target "gui/501/com.wardmast.server"

  setup do
    dir = Path.join(System.tmp_dir!(), "arb-launchd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Process.put(:bd2_launchd_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # Records every command; `fun` answers launchctl calls (`id -u` is always 501).
  defp stub(fun) do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn
      "id", ["-u"], _opts ->
        {"501\n", 0}

      cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args})
        fun.(cmd, args, opts)
    end)
  end

  defp drain_launchctl(acc \\ []) do
    receive do
      {:cmd, "launchctl", args} -> drain_launchctl([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp touch_plist(dir), do: File.write!(Path.join(dir, "com.wardmast.server.plist"), "<plist/>")

  describe "Supervisor.impl_for/1" do
    test "darwin gets launchd, everything else systemd" do
      assert Supervisor.impl_for({:unix, :darwin}) == Launchd
      assert Supervisor.impl_for({:unix, :linux}) == Supervisor.Systemd
    end
  end

  describe "service_state/0" do
    test "launchctl print exit 0 is :managed" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Launchd.service_state() == :managed
      assert_received {:cmd, "launchctl", ["print", @target]}
    end

    test "'could not find service' (exit 113) is :not_found" do
      stub(fn _, _, _ -> {"Could not find service \"com.wardmast.server\" in domain", 113} end)
      assert Launchd.service_state() == :not_found
    end

    test "not loaded but the plist is on disk is still :managed", %{dir: dir} do
      touch_plist(dir)
      stub(fn _, _, _ -> {"Could not find service \"com.wardmast.server\" in domain", 113} end)
      assert Launchd.service_state() == :managed
    end

    test "a missing launchctl binary is :not_found" do
      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert Launchd.service_state() == :not_found
    end

    test "any other failure is unreachable" do
      stub(fn _, _, _ -> {"Bootstrap failed: 5", 5} end)
      assert {:unreachable, "launchctl exited 5: Bootstrap failed: 5"} = Launchd.service_state()
    end
  end

  describe "unit_dirs/0 and unit_file_name/0" do
    test "point at the LaunchAgents dir and the plist", %{dir: dir} do
      assert Launchd.unit_dirs() == [dir]
      assert Launchd.unit_file_name() == "com.wardmast.server.plist"
    end
  end

  describe "stop_service/0" do
    test "boots the job out of the domain (KeepAlive would respawn a plain kill)" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Launchd.stop_service() == :ok
      assert_received {:cmd, "launchctl", ["bootout", @target]}
    end

    test "a service that is not loaded is already stopped" do
      stub(fn _, _, _ -> {"No such process", 3} end)
      assert Launchd.stop_service() == :ok
    end

    test "other failures are errors, and a missing binary does not raise" do
      stub(fn _, _, _ -> {"boom\n", 5} end)
      assert Launchd.stop_service() == {:error, "launchctl bootout exited 5: boom"}

      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert {:error, "could not run launchctl: :enoent"} = Launchd.stop_service()
    end
  end

  describe "restart_service/0" do
    test "kickstart -k kills and restarts a loaded job in one step" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Launchd.restart_service() == :ok
      assert_received {:cmd, "launchctl", ["kickstart", "-k", @target]}
      refute_received {:cmd, "launchctl", ["bootstrap" | _]}
    end

    test "an unloaded job is bootstrapped from its plist", %{dir: dir} do
      touch_plist(dir)
      plist = Path.join(dir, "com.wardmast.server.plist")

      stub(fn
        _, ["kickstart" | _], _ -> {"Could not find service", 113}
        _, ["bootstrap" | _], _ -> {"", 0}
      end)

      assert Launchd.restart_service() == :ok
      assert_received {:cmd, "launchctl", ["kickstart", "-k", @target]}
      assert_received {:cmd, "launchctl", ["bootstrap", "gui/501", ^plist]}
    end

    test "unloaded with no plist is an error that says so" do
      stub(fn _, _, _ -> {"Could not find service", 113} end)

      assert {:error, title, detail} = Launchd.restart_service()
      assert title =~ "com.wardmast.server"
      assert detail =~ "arb install service"
    end

    test "a failed kickstart reports the output" do
      stub(fn _, _, _ -> {"nope\n", 1} end)

      assert {:error, "launchctl kickstart -k " <> _, "Output:\nnope"} = Launchd.restart_service()
    end
  end

  describe "service_info/0" do
    test "a running job is active; there is no InvocationID" do
      stub(fn _, _, _ ->
        {"com.wardmast.server = {\n\tstate = running\n\tpid = 4242\n\truns = 3\n}\n", 0}
      end)

      assert %{state: "active", invocation_id: "", job: nil} = Launchd.service_info()
      assert_received {:cmd, "launchctl", ["print", @target]}
    end

    test "a loaded job that is not running is inactive" do
      stub(fn _, _, _ -> {"com.wardmast.server = {\n\tstate = waiting\n\truns = 3\n}\n", 0} end)
      assert %{state: "inactive"} = Launchd.service_info()
    end

    test "an unreadable job is nil" do
      stub(fn _, _, _ -> {"Could not find service", 113} end)
      assert Launchd.service_info() == nil

      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert Launchd.service_info() == nil
    end
  end

  describe "recover_stuck_service/0" do
    test "boots out, bootstraps again and kickstarts", %{dir: dir} do
      touch_plist(dir)
      plist = Path.join(dir, "com.wardmast.server.plist")
      stub(fn _, _, _ -> {"", 0} end)

      assert Launchd.recover_stuck_service() == :ok
      assert_received {:cmd, "launchctl", ["bootout", @target]}
      assert_received {:cmd, "launchctl", ["bootstrap", "gui/501", ^plist]}
      assert_received {:cmd, "launchctl", ["kickstart", "-k", @target]}
    end

    test "never raises" do
      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert Launchd.recover_stuck_service() == :ok
    end
  end

  describe "list_scopes/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "arb-ls-1347")
      prior = System.get_env("WARDMAST_SOCKET_ROOT")
      System.put_env("WARDMAST_SOCKET_ROOT", root)
      File.mkdir_p!(Path.join(root, "sessions"))

      on_exit(fn ->
        if prior,
          do: System.put_env("WARDMAST_SOCKET_ROOT", prior),
          else: System.delete_env("WARDMAST_SOCKET_ROOT")

        File.rm_rf(root)
      end)

      {:ok, sessions: Path.join(root, "sessions")}
    end

    test "no pidfiles, no scopes" do
      assert Launchd.list_scopes("arb-session-") == {:ok, ""}
    end

    test "a pidfile whose pid is a live tmux is listed in systemctl's column shape", %{
      sessions: dir
    } do
      File.write!(Path.join(dir, "session-aaa.pid"), "4242\n/x/session-aaa.sock\n")
      File.write!(Path.join(dir, "session-bbb.pid"), "4343\n/x/session-bbb.sock\n")

      stub(fn
        "ps", ["-p", "4242" | _], _ -> {"tmux\n", 0}
        "ps", ["-p", "4343" | _], _ -> {"", 1}
      end)

      assert {:ok, out} = Launchd.list_scopes("arb-session-")
      assert [unit, "loaded", "active", "running" | _] = String.split(out)
      assert unit == "arb-session-aaa.scope"
      refute out =~ "bbb"
    end

    test "a recycled pid (not tmux) is not a session", %{sessions: dir} do
      File.write!(Path.join(dir, "session-aaa.pid"), "4242\n/x/session-aaa.sock\n")
      stub(fn "ps", _, _ -> {"Safari\n", 0} end)

      assert Launchd.list_scopes("arb-session-") == {:ok, ""}
    end

    test "ps failing is an error, not an empty list", %{sessions: dir} do
      File.write!(Path.join(dir, "session-aaa.pid"), "4242\n/x/session-aaa.sock\n")
      stub(fn "ps", _, _ -> {"ps: boom\n", 71} end)

      assert {:error, title, detail} = Launchd.list_scopes("arb-session-")
      assert title =~ "ps"
      assert detail =~ "boom"
    end
  end

  describe "install/uninstall callbacks" do
    test "daemon_reload is a no-op (launchd has no unit cache)" do
      assert Launchd.daemon_reload(:user) == :ok
    end

    test "enable_now boots out any old copy, enables the job, then bootstraps the plist", %{
      dir: dir
    } do
      plist = Path.join(dir, "com.wardmast.server.plist")
      stub(fn _, _, _ -> {"", 0} end)

      assert Launchd.enable_now(:user) == :ok

      # `enable` must precede `bootstrap`: a disabled label refuses to bootstrap.
      assert [
               ["bootout", @target],
               ["enable", @target],
               ["bootstrap", "gui/501", ^plist]
             ] = drain_launchctl()
    end

    test "enable_now dies when bootstrap fails" do
      stub(fn
        _, ["bootstrap" | _], _ -> {"Bootstrap failed: 5: Input/output error\n", 5}
        _, _, _ -> {"", 0}
      end)

      {_out, err, code} = capture(fn -> Launchd.enable_now(:user) end)
      assert code == 1
      assert err =~ "launchctl bootstrap"
    end

    test "disable_now reports whether the job was loaded" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Launchd.disable_now(:user) == true
      assert_received {:cmd, "launchctl", ["bootout", @target]}

      stub(fn _, _, _ -> {"No such process", 3} end)
      assert Launchd.disable_now(:user) == false
    end

    test "boot-start and log-rotation timers are not available" do
      assert Launchd.enable_boot_start() == :failed
      assert {_msg, code} = Launchd.enable_timer("x.timer")
      assert code != 0
      assert {_msg, code} = Launchd.disable_timer("x.timer")
      assert code != 0
    end

    test "operator command hints name launchctl, never systemctl" do
      target = "gui/$(id -u)/com.wardmast.server"
      assert Launchd.manager_name() == "launchd"
      assert Launchd.restart_cmd() == "launchctl kickstart -k #{target}"
      assert Launchd.start_cmd() == "launchctl kickstart #{target}"
      assert Launchd.stop_cmd() == "launchctl bootout #{target}"

      recover = Launchd.recover_cmds()
      assert Enum.any?(recover, &(&1 =~ ~r/^launchctl bootout /))

      assert Enum.any?(
               recover,
               &(&1 =~ ~r/^launchctl bootstrap gui\/\$\(id -u\) .*com\.wardmast\.server\.plist$/)
             )

      assert Launchd.status_cmd(:user) in recover
      refute Enum.any?(recover, &(&1 =~ "systemctl"))
    end

    test "status_cmd and logs_cmd name launchctl and the log file" do
      assert Launchd.status_cmd(:user) == "launchctl print gui/$(id -u)/com.wardmast.server"
      assert Launchd.logs_cmd(:user) =~ ~r{^tail -f .*/log/wardmast\.log$}
    end
  end
end
