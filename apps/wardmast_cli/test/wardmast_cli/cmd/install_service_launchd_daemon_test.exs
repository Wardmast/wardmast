defmodule WardmastCli.Cmd.InstallServiceLaunchdDaemonTest do
  # async: false — swaps the Supervisor backend (app env) and uses the
  # process-dict runner seams. No real launchctl/dscl/chown is ever run.
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.InstallService
  alias WardmastCli.Supervisor.Launchd

  @target "system/com.wardmast.server"

  setup do
    prior_backend = Application.get_env(:wardmast_cli, :supervisor)
    Application.put_env(:wardmast_cli, :supervisor, Launchd)

    prior_worker_id = System.get_env("ARB_WORKER_BEAD_ID")
    System.delete_env("ARB_WORKER_BEAD_ID")

    tmp = Path.join(System.tmp_dir!(), "arb-daemon-it-#{System.unique_integer([:positive])}")
    service_home = Path.join(tmp, "Users/_wardmast")
    agents = Path.join(tmp, "LaunchAgents")
    daemons = Path.join(tmp, "LaunchDaemons")
    logs = Path.join(tmp, "Logs/Wardmast")
    File.mkdir_p!(service_home)
    File.mkdir_p!(agents)
    File.mkdir_p!(daemons)

    Process.put(:bd2_launchd_dir, agents)
    Process.put(:bd3_launchd_daemon_dir, daemons)
    Process.put(:bd3_launchd_log_dir, logs)
    Process.put(:bd2_sleep, fn _ -> :ok end)
    stub_transport_error(:get, "/api/workers", :econnrefused)

    on_exit(fn ->
      if prior_backend,
        do: Application.put_env(:wardmast_cli, :supervisor, prior_backend),
        else: Application.delete_env(:wardmast_cli, :supervisor)

      if prior_worker_id, do: System.put_env("ARB_WORKER_BEAD_ID", prior_worker_id)
      File.rm_rf(tmp)
    end)

    {:ok,
     service_home: service_home,
     data_home: Path.join(service_home, ".wardmast"),
     agents: agents,
     daemons: daemons,
     logs: logs}
  end

  # Answers the account lookups for `_wardmast` (home = `home`), root's `id -u`
  # as `uid`, and records everything else as `{:cmd, cmd, args}`.
  defp record_cmds(ctx, opts \\ []) do
    uid = Keyword.get(opts, :uid, "0")
    account_uid = Keyword.get(opts, :account_uid, "399")
    answer = Keyword.get(opts, :answer, fn _, _ -> {"", 0} end)
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn
      "id", ["-u"], _ ->
        {uid <> "\n", 0}

      "id", ["-u", _user], _ ->
        {account_uid <> "\n", 0}

      "id", ["-gn", _user], _ ->
        {"staff\n", 0}

      "dscl", [".", "-read", "/Users/_wardmast", "NFSHomeDirectory"], _ ->
        {"NFSHomeDirectory: #{ctx.service_home}\n", 0}

      "dscl", [".", "-read", "/Users/" <> _, _], _ ->
        {"<dscl_cmd> DS Error: -14136 (eDSRecordNotFound)\n", 56}

      cmd, args, _ ->
        send(test_pid, {:cmd, cmd, args})
        answer.(cmd, args)
    end)
  end

  defp cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args} -> cmds([{cmd, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp plist_path(ctx), do: Path.join(ctx.daemons, "com.wardmast.server.plist")

  describe "ward install service --system (darwin backend)" do
    test "writes a LaunchDaemon plist whose UserName is the service account", ctx do
      record_cmds(ctx)

      {out, _err, code} = capture(fn -> InstallService.run(["--system"]) end)

      assert code == 0
      assert out =~ "LaunchDaemon"

      xml = File.read!(plist_path(ctx))
      assert xml =~ "<key>UserName</key>\n  <string>_wardmast</string>"
      assert xml =~ "<key>GroupName</key>\n  <string>staff</string>"
      assert xml =~ "<string>com.wardmast.server</string>"
      assert xml =~ "<string>#{ctx.data_home}/launchd-run.sh</string>"
      assert xml =~ "<key>HOME</key>\n    <string>#{ctx.service_home}</string>"
      # the data home is pinned explicitly, next to (not instead of) the HOME pin
      assert xml =~ "<key>WARDMAST_DATA_HOME</key>\n    <string>#{ctx.data_home}</string>"
      assert xml =~ "<key>ARB_DATA_HOME</key>\n    <string>#{ctx.data_home}</string>"
      assert xml =~ "/Library/Logs/Wardmast/wardmast.log"
      assert xml =~ "<key>RunAtLoad</key>"
    end

    test "the plist is mode 0644, and chowned to root:wheel", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)

      assert File.stat!(plist_path(ctx)).mode |> Bitwise.band(0o777) == 0o644
      assert {"chown", ["root:wheel", plist_path(ctx)]} in cmds()
    end

    test "the data home is private to the service account (0700) and chowned to it", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)

      assert File.stat!(ctx.data_home).mode |> Bitwise.band(0o777) == 0o700
      assert {"chown", ["-R", "_wardmast:staff", ctx.data_home]} in cmds()
    end

    test "writes the release wrapper into the service account's data home", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)

      wrapper = Path.join(ctx.data_home, "launchd-run.sh")
      script = File.read!(wrapper)
      assert script =~ "exec '#{ctx.data_home}/current/bin/wardmast' start"
      assert File.stat!(wrapper).mode |> Bitwise.band(0o111) != 0
    end

    test "creates the log directory, owned by the service account and closed to others", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)

      assert File.dir?(ctx.logs)
      assert File.stat!(ctx.logs).mode |> Bitwise.band(0o777) == 0o750
      assert {"chown", ["_wardmast:staff", ctx.logs]} in cmds()
    end

    test "bootstraps into the system domain, enabling first", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)

      cmds = cmds()
      plist = plist_path(ctx)
      assert {"launchctl", ["bootstrap", "system", plist]} in cmds
      assert {"launchctl", ["enable", @target]} in cmds

      assert Enum.find_index(cmds, &(&1 == {"launchctl", ["enable", @target]})) <
               Enum.find_index(cmds, &(&1 == {"launchctl", ["bootstrap", "system", plist]}))

      refute Enum.any?(cmds, fn {_, args} -> Enum.any?(args, &(&1 =~ "gui/")) end)
    end

    test "--service-user picks a different account", ctx do
      Process.put(:bd2_cmd_runner, fn
        "id", ["-u"], _ ->
          {"0\n", 0}

        "id", ["-u", "ci"], _ ->
          {"401\n", 0}

        "id", ["-gn", "ci"], _ ->
          {"staff\n", 0}

        "dscl", [".", "-read", "/Users/ci", _], _ ->
          {"NFSHomeDirectory: #{ctx.service_home}\n", 0}

        _, _, _ ->
          {"", 0}
      end)

      assert {_, _, 0} =
               capture(fn -> InstallService.run(["--system", "--service-user", "ci"]) end)

      assert File.read!(plist_path(ctx)) =~ "<key>UserName</key>\n  <string>ci</string>"
    end

    test "--json reports system scope, the account and the plist path", ctx do
      record_cmds(ctx)

      {out, _err, 0} = capture(fn -> InstallService.run(["--system", "--json"]) end)

      assert %{
               "action" => "install",
               "scope" => "system",
               "service_user" => "_wardmast",
               "unit_path" => path,
               "ok" => true
             } = Jason.decode!(out)

      assert path == plist_path(ctx)
    end

    test "re-running is idempotent", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)
    end

    test "is refused for a non-root caller, and writes nothing", ctx do
      record_cmds(ctx, uid: "501")

      assert {_, err, 1} = capture(fn -> InstallService.run(["--system"]) end)
      assert err =~ "root"
      assert err =~ "sudo"
      refute File.exists?(plist_path(ctx))
      assert cmds() == []
    end

    test "is refused when the service account does not exist, with a creation hint", ctx do
      record_cmds(ctx)

      assert {_, err, 1} =
               capture(fn ->
                 InstallService.run(["--system", "--service-user", "nobody_here"])
               end)

      assert err =~ "nobody_here"
      assert err =~ "does not exist"
      assert err =~ "sysadminctl"
      refute File.exists?(plist_path(ctx))
    end

    test "never runs the server as root: --service-user root is refused", ctx do
      record_cmds(ctx)

      assert {_, err, 1} =
               capture(fn -> InstallService.run(["--system", "--service-user", "root"]) end)

      assert err =~ "root"
      refute File.exists?(plist_path(ctx))
    end

    test "an account that resolves to uid 0 is refused too", ctx do
      record_cmds(ctx, account_uid: "0")

      assert {_, err, 1} = capture(fn -> InstallService.run(["--system"]) end)
      assert err =~ "uid 0"
      refute File.exists?(plist_path(ctx))
    end

    test "is refused while a per-user LaunchAgent is installed (two servers, one port)", ctx do
      record_cmds(ctx)
      File.write!(Path.join(ctx.agents, "com.wardmast.server.plist"), "<plist/>")

      assert {_, err, 1} = capture(fn -> InstallService.run(["--system"]) end)
      assert err =~ "LaunchAgent"
      assert err =~ "--uninstall"
      refute File.exists?(plist_path(ctx))
    end

    test "a bootstrap failure exits 1", ctx do
      record_cmds(ctx,
        answer: fn
          "launchctl", ["bootstrap" | _] -> {"Bootstrap failed: 5\n", 5}
          _, _ -> {"", 0}
        end
      )

      assert {_, err, 1} = capture(fn -> InstallService.run(["--system"]) end)
      assert err =~ "launchctl bootstrap system"
    end
  end

  describe "per-user install while a LaunchDaemon exists" do
    test "is refused, pointing at the system uninstall", ctx do
      record_cmds(ctx, uid: "501")
      File.write!(plist_path(ctx), "<plist/>")

      assert {_, err, 1} = capture(fn -> InstallService.run([]) end)
      assert err =~ "LaunchDaemon"
      assert err =~ "--system --uninstall"
    end
  end

  describe "ward install service --system --uninstall" do
    test "boots the system job out and removes the plist, leaving data and account", ctx do
      record_cmds(ctx)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system"]) end)
      _ = cmds()
      assert File.exists?(plist_path(ctx))

      {out, _err, code} = capture(fn -> InstallService.run(["--system", "--uninstall"]) end)

      assert code == 0
      assert out =~ "LaunchDaemon"
      refute File.exists?(plist_path(ctx))
      assert {"launchctl", ["bootout", @target]} in cmds()
      assert File.dir?(ctx.data_home)
    end

    test "needs root", ctx do
      record_cmds(ctx, uid: "501")
      File.write!(plist_path(ctx), "<plist/>")

      assert {_, err, 1} = capture(fn -> InstallService.run(["--system", "--uninstall"]) end)
      assert err =~ "root"
      assert File.exists?(plist_path(ctx))
    end

    test "is idempotent when nothing is installed", ctx do
      record_cmds(ctx, answer: fn _, _ -> {"No such process", 3} end)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--system", "--uninstall"]) end)
    end

    test "a per-user --uninstall points at the daemon instead of silently doing nothing", ctx do
      record_cmds(ctx, uid: "501")
      File.write!(plist_path(ctx), "<plist/>")

      assert {_, err, 1} = capture(fn -> InstallService.run(["--uninstall"]) end)
      assert err =~ "--system --uninstall"
      assert File.exists?(plist_path(ctx))
    end
  end
end
