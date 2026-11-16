defmodule WardmastCli.Supervisor.SystemdTest do
  # async: false — Process-dictionary runner seam (Start.run_cmd).
  use ExUnit.Case, async: false

  alias WardmastCli.Supervisor
  alias WardmastCli.Supervisor.Systemd

  defp stub(fun) do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
      send(test_pid, {:cmd, cmd, args})
      fun.(cmd, args, opts)
    end)
  end

  test "the default supervisor implementation is Systemd" do
    assert Supervisor.impl() == Systemd
  end

  describe "service_state/0" do
    test "exit 0 is :managed" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Systemd.service_state() == :managed
      assert_received {:cmd, "systemctl", ["--user", "cat", "arbiter.service"]}
    end

    test "a not-found message is :not_found" do
      stub(fn _, _, _ -> {"No files found for arbiter.service.", 1} end)
      assert Systemd.service_state() == :not_found
    end

    test "a missing systemctl binary is :not_found" do
      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert Systemd.service_state() == :not_found
    end

    test "any other failure is unreachable" do
      stub(fn _, _, _ -> {"Failed to connect to bus", 1} end)

      assert {:unreachable, "systemctl exited 1: Failed to connect to bus"} =
               Systemd.service_state()
    end
  end

  describe "stop_service/0" do
    test "ok on exit 0, error text otherwise" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Systemd.stop_service() == :ok
      assert_received {:cmd, "systemctl", ["--user", "stop", "arbiter.service"]}

      stub(fn _, _, _ -> {"boom\n", 5} end)
      assert Systemd.stop_service() == {:error, "systemctl stop exited 5: boom"}
    end

    test "a missing binary is an error, not a raise" do
      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert {:error, "could not run systemctl: :enoent"} = Systemd.stop_service()
    end
  end

  describe "restart_service/0" do
    test "enqueues a non-blocking restart" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Systemd.restart_service() == :ok
      assert_received {:cmd, "systemctl", ["--user", "restart", "--no-block", "arbiter.service"]}
    end

    test "failure carries the die title and detail" do
      stub(fn _, _, _ -> {"nope\n", 1} end)

      assert {:error, "systemctl --user restart arbiter.service failed (exit 1)", "Output:\nnope"} =
               Systemd.restart_service()
    end

    test "a missing binary carries the PATH hint" do
      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)

      assert {:error, "could not run systemctl: :enoent", "Ensure systemctl is on your PATH."} =
               Systemd.restart_service()
    end
  end

  describe "service_info/0" do
    test "parses ActiveState/InvocationID/Job" do
      stub(fn _, _, _ -> {"ActiveState=active\nInvocationID=abc\nJob=\n", 0} end)
      assert %{state: "active", invocation_id: "abc", job: ""} = Systemd.service_info()

      assert_received {:cmd, "systemctl",
                       [
                         "--user",
                         "show",
                         "arbiter.service",
                         "-p",
                         "ActiveState",
                         "-p",
                         "InvocationID",
                         "-p",
                         "Job"
                       ]}
    end

    test "nil when unreadable" do
      stub(fn _, _, _ -> {"", 1} end)
      assert Systemd.service_info() == nil
      stub(fn _, _, _ -> raise "x" end)
      assert Systemd.service_info() == nil
    end
  end

  test "recover_stuck_service/0 reexecs then starts" do
    stub(fn _, _, _ -> {"", 0} end)
    assert Systemd.recover_stuck_service() == :ok
    assert_received {:cmd, "systemctl", ["--user", "daemon-reexec"]}
    assert_received {:cmd, "systemctl", ["--user", "start", "--no-block", "arbiter.service"]}
  end

  test "list_scopes/1 lists user units matching the prefix" do
    stub(fn _, _, _ -> {"arb-session-x.scope loaded active running\n", 0} end)
    assert {:ok, "arb-session-x" <> _} = Systemd.list_scopes("arb-session-")

    assert_received {:cmd, "systemctl",
                     ["--user", "list-units", "arb-session-*", "--no-legend", "--plain"]}
  end

  describe "install helpers" do
    test "user scope prefixes --user, system does not" do
      stub(fn _, _, _ -> {"", 0} end)
      assert :ok = Systemd.daemon_reload(:user)
      assert :ok = Systemd.daemon_reload(:system)
      assert_received {:cmd, "systemctl", ["--user", "daemon-reload"]}
      assert_received {:cmd, "systemctl", ["daemon-reload"]}
    end

    test "enable_boot_start/0 uses loginctl enable-linger; failure is :failed" do
      stub(fn _, _, _ -> {"", 0} end)
      assert Systemd.enable_boot_start() == :enabled
      assert_received {:cmd, "loginctl", ["enable-linger" | _]}

      stub(fn _, _, _ -> raise ErlangError, original: :enoent end)
      assert Systemd.enable_boot_start() == :failed
    end

    test "timers go through systemctl --user" do
      stub(fn _, _, _ -> {"", 0} end)
      assert {"", 0} = Systemd.enable_timer("t.timer")
      assert {"", 0} = Systemd.disable_timer("t.timer")
      assert_received {:cmd, "systemctl", ["--user", "enable", "--now", "t.timer"]}
      assert_received {:cmd, "systemctl", ["--user", "disable", "--now", "t.timer"]}
    end

    test "status_cmd/logs_cmd are scope-aware" do
      assert Systemd.status_cmd(:user) == "systemctl --user status arbiter.service"
      assert Systemd.status_cmd(:system) == "systemctl status arbiter.service"
      assert Systemd.logs_cmd(:system) == "journalctl -u arbiter.service -f"
      assert "tail -f " <> _ = Systemd.logs_cmd(:user)
    end
  end

  test "unit_dirs/0 honours the :bd2_unit_dirs seam" do
    Process.put(:bd2_unit_dirs, ["/x"])
    assert Systemd.unit_dirs() == ["/x"]
  end
end
