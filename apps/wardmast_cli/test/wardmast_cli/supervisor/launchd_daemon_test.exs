defmodule WardmastCli.Supervisor.LaunchdDaemonTest do
  # async: false — Process-dictionary runner seams (Start.run_cmd, plist dirs).
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Supervisor.Launchd
  alias WardmastCli.Supervisor.Launchd.Plist

  @system_target "system/com.wardmast.server"

  setup do
    tmp = Path.join(System.tmp_dir!(), "arb-launchd-daemon-#{System.unique_integer([:positive])}")
    agents = Path.join(tmp, "LaunchAgents")
    daemons = Path.join(tmp, "LaunchDaemons")
    File.mkdir_p!(agents)
    File.mkdir_p!(daemons)
    Process.put(:bd2_launchd_dir, agents)
    Process.put(:bd3_launchd_daemon_dir, daemons)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, agents: agents, daemons: daemons}
  end

  # Records every command except `id -u` (answered with `uid`).
  defp stub(uid, fun) do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn
      "id", ["-u"], _opts ->
        {"#{uid}\n", 0}

      cmd, args, opts ->
        send(test_pid, {:cmd, cmd, args})
        fun.(cmd, args, opts)
    end)
  end

  defp launchctl_calls(acc \\ []) do
    receive do
      {:cmd, "launchctl", args} -> launchctl_calls([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write_daemon_plist(daemons, user \\ "_wardmast") do
    xml =
      Plist.plist(
        mode: :daemon,
        user_name: user,
        group_name: "staff",
        user_home: "/Users/#{user}",
        arbiter_home: "/Users/#{user}/.wardmast"
      )

    path = Path.join(daemons, Plist.file_name())
    File.write!(path, xml)
    File.chmod!(path, 0o644)
    path
  end

  describe "service_mode/0" do
    test "no plist anywhere is :none", _ctx do
      assert %{mode: :none, plist: nil} = Launchd.service_mode()
    end

    test "a LaunchAgent plist is :agent", %{agents: agents} do
      File.write!(Path.join(agents, Plist.file_name()), "<plist/>")
      assert %{mode: :agent, plist: plist} = Launchd.service_mode()
      assert plist == Path.join(agents, Plist.file_name())
    end

    test "a LaunchDaemon plist is :daemon and reports the account it runs as", %{daemons: d} do
      path = write_daemon_plist(d)

      assert %{mode: :daemon, plist: ^path, user: "_wardmast", group: "staff", file_mode: 0o644} =
               Launchd.service_mode()
    end

    test "a daemon plist without UserName reports user nil (it would run as root)", %{daemons: d} do
      File.write!(Path.join(d, Plist.file_name()), "<plist><dict></dict></plist>")
      assert %{mode: :daemon, user: nil} = Launchd.service_mode()
    end

    test "both installed is :both (a conflict: two servers, one port)", %{agents: a, daemons: d} do
      File.write!(Path.join(a, Plist.file_name()), "<plist/>")
      write_daemon_plist(d)
      assert %{mode: :both} = Launchd.service_mode()
    end
  end

  describe "with a LaunchDaemon installed, the backend drives the system domain" do
    setup %{daemons: d} do
      {:ok, plist: write_daemon_plist(d)}
    end

    test "service_state prints system/<label>" do
      stub(0, fn _, _, _ -> {"", 0} end)
      assert Launchd.service_state() == :managed
      assert [["print", @system_target]] = launchctl_calls()
    end

    test "an unloaded daemon whose plist exists is still :managed" do
      stub(0, fn _, _, _ -> {"Could not find service", 113} end)
      assert Launchd.service_state() == :managed
    end

    test "restart as root is kickstart -k on the system target" do
      stub(0, fn _, _, _ -> {"", 0} end)
      assert Launchd.restart_service() == :ok
      assert [["kickstart", "-k", @system_target]] = launchctl_calls()
    end

    test "restart as a non-root user is refused with a sudo hint, without touching launchd" do
      stub(501, fn _, _, _ -> {"", 0} end)

      assert {:error, msg, hint} = Launchd.restart_service()
      assert msg =~ "root"
      assert hint =~ "sudo"
      assert launchctl_calls() == []
    end

    test "restart bootstraps an unloaded daemon into the system domain", %{plist: plist} do
      stub(0, fn
        "launchctl", ["kickstart" | _], _ -> {"Could not find service", 113}
        _, _, _ -> {"", 0}
      end)

      assert Launchd.restart_service() == :ok
      assert ["bootstrap", "system", plist] in launchctl_calls()
    end

    test "stop is bootout on the system target" do
      stub(0, fn _, _, _ -> {"", 0} end)
      assert Launchd.stop_service() == :ok
      assert [["bootout", @system_target]] = launchctl_calls()
    end

    test "service_info parses state from the system target" do
      stub(0, fn _, _, _ -> {"x = {\n\tstate = running\n\tpid = 9\n}\n", 0} end)
      assert %{state: "active"} = Launchd.service_info()
      assert [["print", @system_target]] = launchctl_calls()
    end

    test "operator hints are sudo + system target; status/logs point at the system log" do
      assert Launchd.restart_cmd() == "sudo launchctl kickstart -k #{@system_target}"
      assert Launchd.start_cmd() == "sudo launchctl kickstart #{@system_target}"
      assert Launchd.stop_cmd() == "sudo launchctl bootout #{@system_target}"
      assert Launchd.status_cmd(:system) == "sudo launchctl print #{@system_target}"
      assert Launchd.logs_cmd(:system) == "tail -f /Library/Logs/Wardmast/wardmast.log"
      assert Enum.any?(Launchd.recover_cmds(), &(&1 =~ ~r/^sudo launchctl bootstrap system /))
    end

    test "unit_dirs covers both plist directories so a stray plist is never ignored", %{
      agents: a,
      daemons: d
    } do
      assert Launchd.unit_dirs() == [a, d]
    end
  end

  describe "enable_now/1 and disable_now/1 for the :system scope" do
    test "bootout, enable, then bootstrap into the system domain", %{daemons: d} do
      plist = write_daemon_plist(d)
      stub(0, fn _, _, _ -> {"", 0} end)

      assert Launchd.enable_now(:system) == :ok

      assert launchctl_calls() == [
               ["bootout", @system_target],
               ["enable", @system_target],
               ["bootstrap", "system", plist]
             ]
    end

    test "a failed bootstrap exits 1 with the output", %{daemons: d} do
      write_daemon_plist(d)

      stub(0, fn
        "launchctl", ["bootstrap" | _], _ -> {"Bootstrap failed: 5\n", 5}
        _, _, _ -> {"", 0}
      end)

      assert {_out, err, 1} = capture(fn -> Launchd.enable_now(:system) end)
      assert err =~ "launchctl bootstrap system"
    end

    test "disable_now boots the system target out" do
      stub(0, fn _, _, _ -> {"", 0} end)
      assert Launchd.disable_now(:system)
      assert [["bootout", @system_target]] = launchctl_calls()
    end
  end
end
