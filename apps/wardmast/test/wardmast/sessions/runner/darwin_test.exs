defmodule Wardmast.Sessions.Runner.DarwinTest do
  @moduledoc """
  The darwin `Wardmast.Sessions.Runner` (bd-a1pnnv, MAC P3-1): detached tmux
  sessions with no `systemd-run`, liveness by tmux + pidfile.

  The runner is a translation layer over the *same* command vocabulary
  `Wardmast.Sessions` / `Adoption` / `OrphanReaper` already speak, so these
  tests drive it with the real `Sessions.launch_argv/2` output and feed its
  `systemctl`-shaped answers back through the real `Adoption.sweep/1` and
  `OrphanReaper.sweep_once/2`. The OS underneath is a scripted inner runner:
  a stand-in for `tmux` and `ps`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Sessions
  alias Wardmast.Sessions.Adoption
  alias Wardmast.Sessions.Naming
  alias Wardmast.Sessions.OrphanReaper
  alias Wardmast.Sessions.Runner.Darwin
  alias Wardmast.Test.SessionRunnerStub

  @id "0197a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

  setup do
    runtime =
      Wardmast.Test.SessionEnv.short_runtime_dir(
        Path.join(System.tmp_dir!(), "bd-a1pnnv-#{System.unique_integer([:positive])}")
      )

    File.mkdir_p!(Path.join(runtime, "arbiter"))

    prior =
      for k <- [:sessions_runtime_dir, :sessions_darwin_inner_runner, :sessions_runner],
          do: {k, Application.get_env(:wardmast, k)}

    Application.put_env(:wardmast, :sessions_runtime_dir, runtime)
    Application.put_env(:wardmast, :sessions_darwin_inner_runner, SessionRunnerStub)

    on_exit(fn ->
      for {k, v} <- prior do
        if v, do: Application.put_env(:wardmast, k, v), else: Application.delete_env(:wardmast, k)
      end

      File.rm_rf(runtime)
    end)

    {:ok, dir: Path.join(runtime, "arbiter")}
  end

  # A fake host: `alive` is the set of pids `ps` reports as a tmux server;
  # `server_pid` is what a freshly-started tmux server reports for `#{pid}`.
  defp host(opts \\ []) do
    alive = Keyword.get(opts, :alive, [])
    server_pid = Keyword.get(opts, :server_pid, "4242")
    new_session = Keyword.get(opts, :new_session, {"", 0})
    ps = Keyword.get(opts, :ps)

    SessionRunnerStub.script(fn
      "tmux", args, _opts ->
        cond do
          "new-session" in args -> new_session
          "display-message" in args -> {server_pid <> "\n", 0}
          true -> {"", 0}
        end

      "ps", ["-p", pid | _], _opts ->
        cond do
          ps -> ps
          pid in alive -> {"tmux\n", 0}
          true -> {"", 1}
        end

      _command, _args, _opts ->
        {"", 0}
    end)
  end

  defp launch_args(dir, id \\ @id) do
    session = %Wardmast.Sessions.Session{
      id: id,
      cwd: "/tmp",
      tmux_socket: Path.join(dir, "session-#{id}.sock"),
      provider: :claude_code,
      kind: :coordinator
    }

    {"systemd-run", args} = Sessions.launch_argv(session, command: "sleep 600")
    {session, args}
  end

  defp write_pidfile!(dir, id, pid) do
    File.write!(
      Path.join(dir, "session-#{id}.pid"),
      "#{pid}\n#{Path.join(dir, "session-#{id}.sock")}\n"
    )
  end

  describe "systemd-run → detached tmux" do
    test "launches tmux directly, with the systemd-run scope flags stripped", %{dir: dir} do
      host()
      {session, args} = launch_args(dir)

      assert {_out, 0} = Darwin.run("systemd-run", args, stderr_to_stdout: true)

      assert [{"tmux", tmux_args, _} | _] = SessionRunnerStub.calls()
      assert ["-S", socket, "new-session", "-d" | _] = tmux_args
      assert socket == session.tmux_socket
      refute Enum.any?(tmux_args, &String.starts_with?(&1, "--unit"))
      assert "sleep 600" == List.last(tmux_args)
    end

    test "records the tmux server pid and socket in the pidfile", %{dir: dir} do
      host(server_pid: "4242")
      {session, args} = launch_args(dir)

      assert {_, 0} = Darwin.run("systemd-run", args, [])

      assert File.read!(Path.join(dir, Naming.pid_basename(@id))) ==
               "4242\n#{session.tmux_socket}\n"

      assert [_, {"tmux", ["-S", sock, "display-message", "-p" | _], _}] =
               SessionRunnerStub.calls()

      assert sock == session.tmux_socket
    end

    test "passes the caller's env straight to tmux", %{dir: dir} do
      host()
      {_session, args} = launch_args(dir)

      Darwin.run("systemd-run", args, env: [{"FOO", "bar"}], stderr_to_stdout: true)

      assert [{"tmux", _, opts} | _] = SessionRunnerStub.calls()
      assert opts[:env] == [{"FOO", "bar"}]
    end

    test "a failed tmux launch returns its status and leaves no pidfile", %{dir: dir} do
      host(new_session: {"no server\n", 1})
      {_session, args} = launch_args(dir)

      assert {"no server\n", 1} = Darwin.run("systemd-run", args, [])
      refute File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end

    test "an unreadable server pid does not fail the launch (tmux liveness still covers it)",
         %{dir: dir} do
      host(server_pid: "not-a-pid")
      {_session, args} = launch_args(dir)

      assert {_, 0} = Darwin.run("systemd-run", args, [])
      refute File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end
  end

  describe "systemctl list-units" do
    test "lists a session whose pidfile names a live tmux server, in systemctl's column shape",
         %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(alive: ["4242"])

      assert {out, 0} =
               Darwin.run(
                 "systemctl",
                 ["--user", "list-units", Naming.unit_glob(), "--no-legend", "--plain"],
                 stderr_to_stdout: true
               )

      assert [unit, "loaded", "active", "running" | _] = String.split(out)
      assert unit == "arb-session-#{@id}.scope"
    end

    test "omits and removes a pidfile whose pid is dead", %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(alive: [])

      assert {"", 0} = Darwin.run("systemctl", ["--user", "list-units", "arb-session-*"], [])
      refute File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end

    test "a recycled pid that is no longer tmux is not a live session", %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(ps: {"Safari\n", 0})

      assert {"", 0} = Darwin.run("systemctl", ["--user", "list-units", "arb-session-*"], [])
    end

    test "ignores files that are not session pidfiles", %{dir: dir} do
      File.write!(Path.join(dir, "heartbeat-abc"), "x")
      File.write!(Path.join(dir, "session-#{@id}.sock"), "")
      host()

      assert {"", 0} = Darwin.run("systemctl", ["--user", "list-units", "arb-session-*"], [])
    end

    test "when ps itself fails the answer is a failure, never an empty host", %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(ps: {"ps: boom\n", 71})

      assert {out, status} =
               Darwin.run("systemctl", ["--user", "list-units", "arb-session-*"], [])

      assert status != 0
      assert out =~ "boom"
      assert File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end
  end

  describe "systemctl stop" do
    test "kills the tmux server by socket, then the pid if it survived, and drops the pidfile",
         %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(alive: ["4242"])

      assert {_, 0} =
               Darwin.run("systemctl", ["--user", "stop", Naming.scope_unit(@id)], [])

      sock = Path.join(dir, "session-#{@id}.sock")
      assert [{"tmux", ["-S", ^sock, "kill-server"], _}] = SessionRunnerStub.calls("tmux")
      assert [{"kill", ["-TERM", "4242"], _}] = SessionRunnerStub.calls("kill")
      refute File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end

    test "does not signal a pid that already exited", %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(alive: [])

      assert {_, 0} = Darwin.run("systemctl", ["--user", "stop", Naming.scope_unit(@id)], [])
      assert SessionRunnerStub.calls("kill") == []
    end

    test "an unknown unit is a non-zero 'not loaded', like systemctl" do
      host()

      assert {out, status} =
               Darwin.run("systemctl", ["--user", "stop", Naming.scope_unit(@id)], [])

      assert status != 0
      assert out =~ "not loaded"
    end
  end

  test "any other command (tmux itself) passes through untouched" do
    host()

    assert {"", 0} = Darwin.run("tmux", ["-S", "/x.sock", "has-session"], stderr_to_stdout: true)

    assert [{"tmux", ["-S", "/x.sock", "has-session"], [stderr_to_stdout: true]}] =
             SessionRunnerStub.calls()
  end

  describe "through the real lifecycle code" do
    test "Adoption re-adopts a running row via pidfile liveness and ends a vanished one",
         %{dir: dir} do
      live = create_row!("live")
      gone = create_row!("gone")
      Sessions.mark_running(live)
      Sessions.mark_running(gone)

      write_pidfile!(dir, live.id, 4242)
      host(alive: ["4242"])

      assert {:ok, result} = Adoption.sweep(runner: Darwin)

      assert live.id in result.adopted
      assert gone.id in result.ended
      assert result.live_units == 1
    end

    test "Adoption reports a live pidfile with no row as an orphan, and OrphanReaper stops it after grace",
         %{dir: dir} do
      write_pidfile!(dir, @id, 4242)
      host(alive: ["4242"])
      now = DateTime.utc_now()

      {first, seen} = OrphanReaper.sweep_once(%{}, runner: Darwin, now: now, grace_ms: 1000)
      assert [%{session_id: @id}] = first.orphans
      assert first.killed == []

      later = DateTime.add(now, 5, :second)
      {second, _seen} = OrphanReaper.sweep_once(seen, runner: Darwin, now: later, grace_ms: 1000)

      assert [%{session_id: @id}] = second.killed
      sock = Path.join(dir, "session-#{@id}.sock")

      assert [{"tmux", ["-S", ^sock, "kill-server"], _}] =
               SessionRunnerStub.calls("tmux")
               |> Enum.filter(fn {_, a, _} -> "kill-server" in a end)

      refute File.exists?(Path.join(dir, Naming.pid_basename(@id)))
    end

    test "Sessions.kill/2 ends the row and stops the server through the runner", %{dir: dir} do
      session = create_row!("kill")
      Sessions.mark_running(session)
      write_pidfile!(dir, session.id, 4242)
      host(alive: ["4242"])

      assert {:ok, ended} = Sessions.kill(session.id, runner: Darwin)
      assert ended.status == :ended
      refute File.exists?(Path.join(dir, Naming.pid_basename(session.id)))
    end
  end

  describe "default runner" do
    test "Sessions.runner/1 picks Darwin on darwin and Host elsewhere" do
      Application.delete_env(:wardmast, :sessions_runner)
      prior = Application.get_env(:wardmast, :sessions_os)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:wardmast, :sessions_os, prior),
          else: Application.delete_env(:wardmast, :sessions_os)
      end)

      Application.put_env(:wardmast, :sessions_os, :darwin)
      assert Sessions.runner() == Darwin

      Application.put_env(:wardmast, :sessions_os, :linux)
      assert Sessions.runner() == Wardmast.Sessions.Runner.Host
    end
  end

  defp create_row!(tag) do
    Ash.create!(Wardmast.Sessions.Session, %{cwd: "/tmp/#{tag}"})
  end
end
