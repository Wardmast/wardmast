defmodule WardmastCli.Cmd.ReleaseDeployLaunchdTest do
  # The launchd twin of the systemd cases in `release_deploy_test.exs`: the
  # same deploy / health-wait / auto-rollback / cross-migration-rollback state
  # machine, driven through `Supervisor.Launchd` with a fake `launchctl`. No
  # real launchctl (or systemctl) is ever run.
  #
  # async: false — swaps the Supervisor backend (app env), mutates global env
  # (ARB_DATA_HOME, ...) and uses the process-dict runner seams.
  use WardmastCli.CliCase, async: false

  alias WardmastCli.Cmd.ReleaseDeploy
  alias WardmastCli.Cmd.ReleaseDeploy.Status
  alias WardmastCli.Supervisor.Launchd

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}
  @empty %{"data" => []}
  @no_workers %{"data" => []}
  @target "gui/501/com.wardmast.server"
  @m_base "20250101000000_create_base"
  @m_old "20260101000000_create_things"
  @m_new "20260202000000_add_flag_to_things"
  @magic "SQLite format 3\0"

  setup do
    prior_backend = Application.get_env(:wardmast_cli, :supervisor)
    Application.put_env(:wardmast_cli, :supervisor, Launchd)

    tmp = Path.join(System.tmp_dir!(), "arb-rel-ld-#{System.unique_integer([:positive])}")
    home = Path.join(tmp, "data")
    agents = Path.join(tmp, "LaunchAgents")
    File.mkdir_p!(home)
    File.mkdir_p!(agents)

    System.put_env("ARB_DATA_HOME", home)
    System.put_env("WARDMAST_INSTALL_BIN", Path.join(home, "bin/ward"))

    for v <-
          ~w(ARB_INSTALL_BIN DATABASE_PATH ARB_DEPLOY_BACKUP_RETAIN WARDMAST_HOST ARB_HOST
             GITHUB_TOKEN ARB_WORKER_BEAD_ID ARB_GITHUB_API),
        do: System.delete_env(v)

    Process.delete(:bd2_deploy_status_path)
    Process.put(:bd2_launchd_dir, agents)
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    Process.put(:bd2_port_check, fn _port -> true end)
    Process.put(:bd2_host_platform, {:darwin, "arm64"})
    Process.put(:bd2_port_owner, fn _port -> :none end)

    on_exit(fn ->
      if prior_backend,
        do: Application.put_env(:wardmast_cli, :supervisor, prior_backend),
        else: Application.delete_env(:wardmast_cli, :supervisor)

      System.delete_env("ARB_DATA_HOME")
      System.delete_env("WARDMAST_INSTALL_BIN")
      File.rm_rf(tmp)
    end)

    {:ok, home: home, agents: agents}
  end

  # ---- fixtures ----------------------------------------------------------

  defp local_tarball(migrations \\ [@m_base]) do
    path = Path.join(System.tmp_dir!(), "ld-rel-#{System.unique_integer([:positive])}.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(tar, "#!/bin/sh\necho arbiter\n", ~c"bin/wardmast", [])

    for m <- migrations do
      :ok =
        :erl_tar.add(
          tar,
          "defmodule M do end",
          ~c"lib/wardmast-0.0.0/priv/repo/migrations/#{m}.exs",
          []
        )
    end

    :ok = :erl_tar.close(tar)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp seed_release(home, tag, migrations \\ [@m_base]) do
    dir = Path.join([home, "releases", tag])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/wardmast"), "old")
    mdir = Path.join(dir, "lib/wardmast-#{String.trim_leading(tag, "v")}/priv/repo/migrations")
    File.mkdir_p!(mdir)
    for m <- migrations, do: File.write!(Path.join(mdir, m <> ".exs"), "defmodule M do end")
    link = Path.join(home, "current")
    File.rm(link)
    File.ln_s!(dir, link)
    dir
  end

  defp stub_local_apis(workspaces \\ @green) do
    stub_routes([
      {{"get", "/api/workspaces"}, {workspaces, 200}},
      {{"get", "/api/repos"},
       {%{"data" => [%{"name" => "tonic", "source" => "acme", "path" => "/srv/tonic"}]}, 200}},
      {{"get", "/api/workers"}, {@no_workers, 200}}
    ])
  end

  # Fake `launchctl`. `:job_state` is what `launchctl print` reports
  # ("running" → active, anything else → the job never comes up);
  # `:on_restart` fires on each `kickstart`; `:answer` overrides any call
  # (return `:default` to fall through).
  defp stub_launchctl(opts \\ []) do
    test_pid = self()
    job_state = Keyword.get(opts, :job_state, "running")
    on_restart = Keyword.get(opts, :on_restart, fn -> :ok end)
    answer = Keyword.get(opts, :answer, fn _, _ -> :default end)

    Process.put(:bd2_cmd_runner, fn cmd, args, run_opts ->
      send(test_pid, {:cmd, cmd, args})

      case answer.(cmd, args) do
        :default -> default_launchctl(cmd, args, run_opts, job_state, on_restart)
        reply -> reply
      end
    end)
  end

  defp default_launchctl("id", ["-u"], _, _, _), do: {"501\n", 0}

  defp default_launchctl("launchctl", ["print", _], _, state, _),
    do: {"com.wardmast.server = {\n\tstate = #{state}\n}\n", 0}

  defp default_launchctl("launchctl", ["kickstart" | _], _, _, on_restart) do
    on_restart.()
    {"", 0}
  end

  defp default_launchctl(_cmd, _args, _, _, _), do: {"", 0}

  defp drain_cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args} -> drain_cmds([{cmd, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp kickstarts(cmds),
    do: Enum.filter(cmds, &(&1 == {"launchctl", ["kickstart", "-k", @target]}))

  defp refute_systemd(cmds),
    do: refute(Enum.any?(cmds, fn {c, _} -> c in ["systemctl", "loginctl", "journalctl"] end))

  # ---- happy path --------------------------------------------------------

  describe "release deploy through launchd (happy path)" do
    test "unpacks, swaps current, kickstarts the job and waits for green", %{home: home} do
      stub_local_apis()
      stub_launchctl()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)

      assert code == 0
      assert out =~ "Wardmast restarted"
      assert out =~ "[ ok ] phoenix reachable"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) |> String.starts_with?("local-")
      assert File.exists?(Path.join(link_target, "bin/wardmast"))

      cmds = drain_cmds()
      assert length(kickstarts(cmds)) == 1
      refute_systemd(cmds)
      # no lsof/SIGTERM path: the launchd job owns the process
      refute Enum.any?(cmds, fn {c, _} -> c in ["lsof", "kill"] end)
    end

    test "the swap happens before the kickstart, so the new job execs the new release",
         %{home: home} do
      seed_release(home, "v0.0.2")
      stub_local_apis()
      test_pid = self()

      stub_launchctl(
        on_restart: fn ->
          send(test_pid, {:current_at_restart, File.read_link(Path.join(home, "current"))})
        end
      )

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)

      assert_received {:current_at_restart, {:ok, target}}
      assert Path.basename(target) |> String.starts_with?("local-")
    end

    test "an installed-but-unloaded agent is bootstrapped from its plist", %{
      home: home,
      agents: agents
    } do
      plist = Path.join(agents, "com.wardmast.server.plist")
      File.write!(plist, "<plist/>")
      stub_local_apis()
      loaded = :counters.new(1, [])
      not_loaded = "Could not find service \"com.wardmast.server\" in domain"

      stub_launchctl(
        answer: fn
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
            :default
        end
      )

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)

      assert {"launchctl", ["bootstrap", "gui/501", plist]} in drain_cmds()
      assert File.exists?(Path.join(home, "current"))
    end
  end

  describe "PATH refresh in wardmast.env (read by the launchd wrapper)" do
    test "deploy writes the deploying shell's PATH into wardmast.env", %{home: home} do
      stub_local_apis()
      stub_launchctl()

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/deploy/shell/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)

      # The env file lands in the data home — the file the release wrapper
      # (`Plist.wrapper_script/1`) exports from on every (re)start.
      assert File.read!(Path.join(home, "wardmast.env")) =~ "PATH=/deploy/shell/bin:/usr/bin"
    end

    test "the env is written before the kickstart, so the restarted job inherits it",
         %{home: home} do
      stub_local_apis()
      test_pid = self()

      stub_launchctl(
        on_restart: fn ->
          send(test_pid, {:env_at_restart, File.exists?(Path.join(home, "wardmast.env"))})
        end
      )

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)
      assert_received {:env_at_restart, true}
    end
  end

  # ---- job never comes up --------------------------------------------------

  describe "server DOWN after restart" do
    test "attempts one recovery, then reports launchctl (not systemctl) recovery steps",
         %{home: home} do
      seed_release(home, "v0.0.2")
      stub_local_apis(@empty)
      stub_launchctl(job_state: "waiting")

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", local_tarball()]) end)

      assert code == 1
      assert out =~ "server is DOWN"
      assert out =~ "launchctl"
      refute out =~ "systemctl"
      refute out =~ "daemon-reexec"
      assert out =~ "was NOT installed"

      # The new release stays current (a rollback restart would hit the same
      # wedge); the exact rollback names the launchd start command.
      assert {:ok, link} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link) |> String.starts_with?("local-")
      assert out =~ "ln -sfn "
      assert out =~ "launchctl kickstart"

      cmds = drain_cmds()
      # the one stuck-start recovery boots the job out before re-loading it
      assert {"launchctl", ["bootout", @target]} in cmds
      refute_systemd(cmds)
    end
  end

  # ---- auto-rollback ------------------------------------------------------

  describe "auto-rollback on a failed health check" do
    test "re-points current at the prior release and kickstarts again, exits 1",
         %{home: home} do
      prior = seed_release(home, "v0.0.2")
      stub_local_apis(@empty)
      stub_launchctl()

      {out, _err, code} =
        capture(fn -> ReleaseDeploy.run(["--local", local_tarball(), "--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Rolled back to v0.0.2"
      assert {:ok, ^prior} = File.read_link(Path.join(home, "current"))

      cmds = drain_cmds()
      # one restart for the new release, one for the rollback
      assert length(kickstarts(cmds)) == 2
      refute_systemd(cmds)
    end

    test "no prior release: reports the stack is down, leaves the new release current",
         %{home: home} do
      stub_local_apis(@empty)
      stub_launchctl()

      {out, _err, code} =
        capture(fn -> ReleaseDeploy.run(["--local", local_tarball(), "--timeout", "1"]) end)

      assert code == 1
      assert out =~ "No prior release to roll back to"
      assert {:ok, link} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link) |> String.starts_with?("local-")
      assert length(kickstarts(drain_cmds())) == 1
    end
  end

  # ---- cross-migration rollback: stop → restore → swap → restart ----------

  describe "rollback that crosses a migration (database restore)" do
    defp db_file(home), do: Path.join(home, "arbiter.sqlite3")
    defp write_db(home, content), do: File.write!(db_file(home), @magic <> content)

    # Stand-in for `bin/wardmast eval Wardmast.Release.Backup.eval_from_env()`.
    defp stub_backup do
      base = Process.get(:bd2_cmd_runner)

      Process.put(:bd2_cmd_runner, fn cmd, args, run_opts ->
        case args do
          ["eval", "Wardmast.Release.Backup.eval_from_env()"] ->
            env = Map.new(run_opts[:env])
            File.mkdir_p!(Path.dirname(env["ARB_BACKUP_DEST"]))
            File.cp!(env["ARB_BACKUP_SRC"], env["ARB_BACKUP_DEST"])
            {Jason.encode!(%{ok: true}), 0}

          _ ->
            base.(cmd, args, run_opts)
        end
      end)
    end

    # restart #1 is the new release booting (migrates the DB, never goes
    # green); restart #2 is the prior release coming back green.
    defp migrating_restarts(home) do
      fn ->
        n = (Process.get(:restarts) || 0) + 1
        Process.put(:restarts, n)

        case n do
          1 -> write_db(home, "migrated-by-new-release")
          _ -> stub_local_apis(@green)
        end
      end
    end

    test "boots the job out (database safe to touch), restores, then kickstarts the prior release",
         %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      write_db(home, "v0.0.2-data")
      stub_local_apis(@empty)
      stub_launchctl(on_restart: migrating_restarts(home))
      stub_backup()

      {out, _err, code} =
        capture(fn ->
          ReleaseDeploy.run(["--local", local_tarball([@m_old, @m_new]), "--timeout", "1"])
        end)

      assert code == 1
      assert out =~ "Rolled back to v0.0.2"
      assert out =~ "Restored the database"
      assert File.read!(db_file(home)) == @magic <> "v0.0.2-data"
      assert {:ok, ^prior} = File.read_link(Path.join(home, "current"))

      cmds = drain_cmds()
      stop_at = Enum.find_index(cmds, &(&1 == {"launchctl", ["bootout", @target]}))
      assert stop_at, "rollback must `launchctl bootout` before touching the database"

      kicks =
        cmds
        |> Enum.with_index()
        |> Enum.filter(fn {c, _} -> c == {"launchctl", ["kickstart", "-k", @target]} end)

      assert length(kicks) == 2
      {_, last_kick} = List.last(kicks)
      assert stop_at < last_kick
      refute_systemd(cmds)

      assert %{"state" => "rolled_back", "restored_database" => true} = Status.read()
    end

    test "a bootout that fails leaves the database alone and refuses", %{home: home} do
      seed_release(home, "v0.0.2", [@m_old])
      write_db(home, "v0.0.2-data")
      stub_local_apis(@empty)

      stub_launchctl(
        on_restart: migrating_restarts(home),
        answer: fn
          "launchctl", ["bootout", _] -> {"Boot-out failed: 5: Input/output error", 5}
          _, _ -> :default
        end
      )

      stub_backup()

      {out, _err, 1} =
        capture(fn ->
          ReleaseDeploy.run(["--local", local_tarball([@m_old, @m_new]), "--timeout", "1"])
        end)

      assert out =~ "Refused to roll back"
      assert out =~ "could not stop"
      assert out =~ "launchctl bootout"
      refute out =~ "systemctl"
      assert File.read!(db_file(home)) == @magic <> "migrated-by-new-release"
    end
  end
end
