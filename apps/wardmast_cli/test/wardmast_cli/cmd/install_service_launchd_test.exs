defmodule WardmastCli.Cmd.InstallServiceLaunchdTest do
  # async: false — swaps the Supervisor backend (app env) and uses the
  # process-dict runner seams. No real launchctl is ever run.
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.{InstallService, Restart}
  alias WardmastCli.Supervisor.Launchd

  @target "gui/501/com.wardmast.server"

  setup do
    prior_backend = Application.get_env(:wardmast_cli, :supervisor)
    Application.put_env(:wardmast_cli, :supervisor, Launchd)

    prior_worker_id = System.get_env("ARB_WORKER_BEAD_ID")
    System.delete_env("ARB_WORKER_BEAD_ID")

    tmp = Path.join(System.tmp_dir!(), "arb-launchd-it-#{System.unique_integer([:positive])}")
    root = Path.join(tmp, "checkout")
    arbiter_home = Path.join(tmp, "home")
    agents = Path.join(tmp, "LaunchAgents")
    File.mkdir_p!(Path.join(root, "apps"))
    File.write!(Path.join(root, "mix.exs"), "# fake umbrella mix.exs\n")
    File.mkdir_p!(arbiter_home)

    System.put_env("ARB_HOME", root)
    Process.put(:bd2_arbiter_home, arbiter_home)
    Process.put(:bd2_launchd_dir, agents)
    Process.put(:bd2_sleep, fn _ -> :ok end)
    stub_transport_error(:get, "/api/workers", :econnrefused)

    on_exit(fn ->
      if prior_backend,
        do: Application.put_env(:wardmast_cli, :supervisor, prior_backend),
        else: Application.delete_env(:wardmast_cli, :supervisor)

      System.delete_env("ARB_HOME")
      if prior_worker_id, do: System.put_env("ARB_WORKER_BEAD_ID", prior_worker_id)
      File.rm_rf(tmp)
    end)

    {:ok, root: root, arbiter_home: arbiter_home, agents: agents}
  end

  defp make_release_bin(home) do
    bin = Path.join([home, "current", "bin", "wardmast"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\n")
    File.chmod!(bin, 0o755)
  end

  defp record_cmds(answer \\ fn _, _ -> {"", 0} end) do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn
      "id", ["-u"], _ ->
        {"501\n", 0}

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

  describe "arb install service (darwin backend)" do
    test "writes the plist, wrapper and run-server.sh, then bootstraps", %{
      root: root,
      arbiter_home: home,
      agents: agents
    } do
      record_cmds()
      plist = Path.join(agents, "com.wardmast.server.plist")

      {out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      assert out =~ "com.wardmast.server"

      xml = File.read!(plist)
      assert xml =~ "<string>com.wardmast.server</string>"
      assert xml =~ "<string>#{home}/launchd-run.sh</string>"
      assert xml =~ "<string>#{root}</string>"
      assert xml =~ "#{home}/log/wardmast.log"

      wrapper = Path.join(home, "launchd-run.sh")
      assert File.read!(wrapper) =~ "wardmast.env"
      assert File.stat!(wrapper).mode |> Bitwise.band(0o111) != 0
      assert File.exists?(Path.join(root, ".run-server.sh"))

      cmds = cmds()
      assert {"launchctl", ["bootstrap", "gui/501", plist]} in cmds
      assert {"launchctl", ["enable", @target]} in cmds

      # a disabled label refuses to bootstrap, so enable comes first
      assert Enum.find_index(cmds, &(&1 == {"launchctl", ["enable", @target]})) <
               Enum.find_index(cmds, &(&1 == {"launchctl", ["bootstrap", "gui/501", plist]}))

      refute Enum.any?(cmds, fn {c, _} -> c in ["systemctl", "loginctl"] end)
    end

    test "--json reports the action and the plist path", %{agents: agents} do
      record_cmds()

      {out, _err, 0} = capture(fn -> InstallService.run(["--json"]) end)

      assert %{"action" => "install", "unit_path" => path, "ok" => true} = Jason.decode!(out)
      assert path == Path.join(agents, "com.wardmast.server.plist")
    end

    test "re-running is idempotent" do
      record_cmds()
      assert {_, _, 0} = capture(fn -> InstallService.run([]) end)
      assert {_, _, 0} = capture(fn -> InstallService.run([]) end)
    end

    test "a bootstrap failure exits 1" do
      record_cmds(fn
        "launchctl", ["bootstrap" | _] -> {"Bootstrap failed: 5\n", 5}
        _, _ -> {"", 0}
      end)

      assert {_, err, 1} = capture(fn -> InstallService.run([]) end)
      assert err =~ "launchctl bootstrap"
    end

    test "a release install (not a dev checkout) writes a release plist and bootstraps", %{
      root: root,
      arbiter_home: home,
      agents: agents
    } do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      make_release_bin(home)
      record_cmds()
      plist = Path.join(agents, "com.wardmast.server.plist")

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      xml = File.read!(plist)
      assert xml =~ "<string>#{home}/launchd-run.sh</string>"
      assert xml =~ "<key>WorkingDirectory</key>\n  <string>#{home}</string>"
      refute xml =~ root

      wrapper = File.read!(Path.join(home, "launchd-run.sh"))
      assert wrapper =~ "exec '#{home}/current/bin/wardmast' start"
      refute wrapper =~ ".run-server.sh"
      refute File.exists?(Path.join(root, ".run-server.sh"))

      cmds = cmds()
      assert {"launchctl", ["bootstrap", "gui/501", plist]} in cmds
      refute Enum.any?(cmds, fn {c, _} -> c in ["systemctl", "loginctl"] end)
    end

    test "a release install fails without loading a job when current/bin/wardmast is missing", %{
      root: root,
      arbiter_home: home,
      agents: agents
    } do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      record_cmds()

      assert {_, err, 1} = capture(fn -> InstallService.run([]) end)
      assert err =~ "#{home}/current/bin/wardmast"
      refute File.exists?(Path.join(agents, "com.wardmast.server.plist"))
      refute File.exists?(Path.join(home, "launchd-run.sh"))
      assert cmds() == []
    end

    test "a release install honours ARB_HOME's .wardmast data home", %{
      root: root,
      agents: agents
    } do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      Process.delete(:bd2_arbiter_home)
      data = Path.join(root, ".wardmast")
      make_release_bin(data)
      File.write!(Path.join(data, "wardmast.env"), "SECRET_KEY_BASE=abc\n")
      record_cmds()

      {_out, _err, code} = capture(fn -> InstallService.run([]) end)

      assert code == 0
      xml = File.read!(Path.join(agents, "com.wardmast.server.plist"))
      assert xml =~ "<key>WorkingDirectory</key>\n  <string>#{data}</string>"
      wrapper = File.read!(Path.join(data, "launchd-run.sh"))
      assert wrapper =~ "exec '#{data}/current/bin/wardmast' start"
      assert wrapper =~ "'#{data}/wardmast.env'"
    end

    test "the release plist pins the ARB_HOME-derived data home, not the real HOME's (bd-56wi24)",
         %{root: root, agents: agents} do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      Process.delete(:bd2_arbiter_home)
      data = Path.join(root, ".wardmast")
      make_release_bin(data)
      real_default = Path.join(System.user_home!(), ".wardmast/launchd-run.sh")
      existed? = File.exists?(real_default)
      record_cmds()

      {_out, _err, 0} = capture(fn -> InstallService.run([]) end)

      xml = File.read!(Path.join(agents, "com.wardmast.server.plist"))
      assert xml =~ "<key>WARDMAST_DATA_HOME</key>\n    <string>#{data}</string>"
      assert xml =~ "<key>ARB_DATA_HOME</key>\n    <string>#{data}</string>"
      refute xml =~ "<key>HOME</key>"
      assert File.exists?(Path.join(data, "launchd-run.sh"))
      # the real user's data home is not touched (the wrapper lands under ARB_HOME)
      assert File.exists?(real_default) == existed?
    end

    test "an explicit WARDMAST_DATA_HOME wins over ARB_HOME and is reported as such",
         %{root: root, agents: agents} do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      Process.delete(:bd2_arbiter_home)
      explicit = Path.join(Path.dirname(root), "explicit-data")
      make_release_bin(explicit)
      System.put_env("WARDMAST_DATA_HOME", explicit)
      on_exit(fn -> System.delete_env("WARDMAST_DATA_HOME") end)
      record_cmds()

      {out, _err, 0} = capture(fn -> InstallService.run(["--json"]) end)

      xml = File.read!(Path.join(agents, "com.wardmast.server.plist"))
      assert xml =~ "<key>WARDMAST_DATA_HOME</key>\n    <string>#{explicit}</string>"

      assert %{"data_home" => ^explicit, "data_home_source" => "explicit_env"} =
               Jason.decode!(out)
    end

    test "the summary prints the data home and its source (text, release via ARB_HOME)",
         %{root: root} do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      Process.delete(:bd2_arbiter_home)
      data = Path.join(root, ".wardmast")
      make_release_bin(data)
      record_cmds()

      {out, _err, 0} = capture(fn -> InstallService.run([]) end)
      assert out =~ "data:   #{data} (ARB_HOME release)"

      {json, _err, 0} = capture(fn -> InstallService.run(["--json"]) end)

      assert %{"data_home" => ^data, "data_home_source" => "arb_home_release"} =
               Jason.decode!(json)
    end

    test "a dev install never copies ARB_HOME into the data home and exports no pin",
         %{root: root, agents: agents, arbiter_home: home} do
      record_cmds()

      {out, _err, 0} = capture(fn -> InstallService.run(["--json"]) end)

      xml = File.read!(Path.join(agents, "com.wardmast.server.plist"))
      refute xml =~ "DATA_HOME"
      assert xml =~ "<key>ARB_HOME</key>\n    <string>#{root}</string>"
      assert %{"data_home" => ^home, "data_home_source" => "default"} = Jason.decode!(out)
    end

    test "warns when the data home differs from the real user's default and the global label is already installed",
         %{root: root, arbiter_home: home} do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      make_release_bin(home)
      real_home = Path.join(Path.dirname(root), "real-home")
      real_plist = Path.join([real_home, "Library", "LaunchAgents", "com.wardmast.server.plist"])
      File.mkdir_p!(Path.dirname(real_plist))
      File.write!(real_plist, "<plist/>")

      record_cmds(fn
        "id", ["-un"] ->
          {"alice\n", 0}

        "dscl", [".", "-read", "/Users/alice", "NFSHomeDirectory"] ->
          {"NFSHomeDirectory: #{real_home}\n", 0}

        _, _ ->
          {"", 0}
      end)

      {_out, err, 0} = capture(fn -> InstallService.run([]) end)

      assert err =~ "warning: the data home #{home} differs from the real default"
      assert err =~ real_plist
      assert err =~ "com.wardmast.server"
    end

    test "no warning when the data home is the real user's default",
         %{root: root} do
      File.rm_rf!(Path.join(root, "apps"))
      File.rm!(Path.join(root, "mix.exs"))
      real_home = Path.join(Path.dirname(root), "real-home")
      data = Path.join(real_home, ".wardmast")
      Process.put(:bd2_arbiter_home, data)
      make_release_bin(data)
      real_plist = Path.join([real_home, "Library", "LaunchAgents", "com.wardmast.server.plist"])
      File.mkdir_p!(Path.dirname(real_plist))
      File.write!(real_plist, "<plist/>")

      record_cmds(fn
        "id", ["-un"] ->
          {"alice\n", 0}

        "dscl", [".", "-read", "/Users/alice", "NFSHomeDirectory"] ->
          {"NFSHomeDirectory: #{real_home}\n", 0}

        _, _ ->
          {"", 0}
      end)

      {_out, err, 0} = capture(fn -> InstallService.run([]) end)
      refute err =~ "differs from the real default"
    end

    test "--system without root is refused (the LaunchDaemon install needs root)" do
      record_cmds()
      assert {_, err, 1} = capture(fn -> InstallService.run(["--system"]) end)
      assert err =~ "needs root"
    end
  end

  describe "arb install service --uninstall (darwin backend)" do
    test "boots the job out and removes the plist", %{agents: agents} do
      record_cmds()
      assert {_, _, 0} = capture(fn -> InstallService.run([]) end)
      _ = cmds()
      plist = Path.join(agents, "com.wardmast.server.plist")
      assert File.exists?(plist)

      {out, _err, code} = capture(fn -> InstallService.run(["--uninstall"]) end)

      assert code == 0
      assert out =~ "com.wardmast.server"
      refute File.exists?(plist)
      assert {"launchctl", ["bootout", @target]} in cmds()
    end

    test "is idempotent when nothing is installed" do
      record_cmds(fn _, _ -> {"No such process", 3} end)
      assert {_, _, 0} = capture(fn -> InstallService.run(["--uninstall"]) end)
    end
  end

  describe "arb restart / stop dispatch" do
    test "restart goes through kickstart -k and verifies the job is running" do
      stub_get("/api/workspaces", %{
        "data" => [%{"id" => "ws-1", "name" => "d", "prefix" => "bd"}]
      })

      record_cmds(fn
        "launchctl", ["print", _] -> {"x = {\n\tstate = running\n\tpid = 7\n}\n", 0}
        _, _ -> {"", 0}
      end)

      assert {:ok, [{:systemd_restart, :ok, nil}], _} = Restart.perform("/tmp/x", 5_000)

      cmds = cmds()
      assert {"launchctl", ["kickstart", "-k", @target]} in cmds
      refute Enum.any?(cmds, fn {c, _} -> c == "systemctl" end)
    end

    test "restart bootstraps an installed-but-unloaded agent from its plist", %{agents: agents} do
      stub_get("/api/workspaces", %{
        "data" => [%{"id" => "ws-1", "name" => "d", "prefix" => "bd"}]
      })

      File.mkdir_p!(agents)
      plist = Path.join(agents, "com.wardmast.server.plist")
      File.write!(plist, "<plist/>")

      not_loaded = "Could not find service \"com.wardmast.server\" in domain"
      loaded = :counters.new(1, [])

      record_cmds(fn
        "launchctl", ["bootstrap" | _] ->
          :counters.put(loaded, 1, 1)
          {"", 0}

        "launchctl", ["print", _] ->
          if :counters.get(loaded, 1) == 1,
            do: {"x = {\n\tstate = running\n}\n", 0},
            else: {not_loaded, 113}

        "launchctl", ["kickstart" | _] ->
          {not_loaded, 113}

        _, _ ->
          {"", 0}
      end)

      assert {:ok, [{:systemd_restart, :ok, nil}], _} = Restart.perform("/tmp/x", 5_000)
      assert {"launchctl", ["bootstrap", "gui/501", plist]} in cmds()
    end

    test "stop boots the job out" do
      record_cmds()
      assert Restart.stop("/tmp/x") == :ok
      assert {"launchctl", ["bootout", @target]} in cmds()
    end
  end
end
