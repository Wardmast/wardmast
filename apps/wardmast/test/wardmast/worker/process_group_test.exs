defmodule Wardmast.Worker.ProcessGroupTest do
  # bd-568ib9 (MAC P2-1): a worker's agent leads its own session and process
  # group, so everything it leaves behind can be killed as one group — after it
  # exits, on server shutdown and, after a crash, by the boot sweep (pid-reuse
  # safe via the recorded start time).
  #
  # Real OS processes throughout, each the leader of its own group (every Erlang
  # port child is: `erl_child_setup` calls setsid()), and every one this file
  # starts is group-killed again on exit. The pid-reuse cases that cannot be
  # staged for real (a reused pid, a gone leader) inject `ps` / `kill`.
  use ExUnit.Case, async: true

  alias Wardmast.Test.OrphanedAgent
  alias Wardmast.Worker.OsProcess
  alias Wardmast.Worker.ProcessGroup

  # ---- helpers ---------------------------------------------------------------

  # Every script prints its own pid first (`Port.info/2` is nil once a quick
  # script's port has closed); it is the port's OS pid, the agent being exec'd
  # in place.
  defp open_sh(script), do: open_port("/bin/sh", ["-c", "echo $$; " <> script])

  defp open_wrapped(%{exec: exec, argv: [_ | args]}), do: open_port(exec, args)

  defp open_port(exec, args) do
    port =
      Port.open({:spawn_executable, exec}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args: args
      ])

    os_pid = int_line(port)
    on_exit(fn -> kill_group(os_pid) end)
    {port, os_pid}
  end

  defp sh_args(script),
    do: %{exec: "/bin/sh", argv: ["/bin/sh", "-c", "echo $$; " <> script], cd: "/"}

  defp kill_group(pgid),
    do: System.cmd("kill", ["-KILL", "--", "-#{pgid}"], stderr_to_stdout: true)

  defp kill_pid(pid), do: System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  defp line(port, timeout \\ 5_000) do
    receive do
      {^port, {:data, {:eol, line}}} -> line
    after
      timeout -> flunk("no output line from the port within #{timeout} ms")
    end
  end

  defp int_line(port), do: port |> line() |> String.trim() |> String.to_integer()

  defp eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("eventually/2 timed out")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end

  # A `ps` that answers for one pid only, the way `ps -o pgid=,ppid=,lstart= -p`
  # does.
  defp fake_ps(answers) do
    fn pid ->
      case Map.fetch(answers, pid) do
        {:ok, out} -> {out, 0}
        :error -> {"", 1}
      end
    end
  end

  # Records every signal sent; a `kill -0` probe afterwards finds the group gone.
  defp recording_kill(test_pid) do
    fn
      ["-0" | _] ->
        {"", 1}

      args ->
        send(test_pid, {:kill, args})
        {"", 0}
    end
  end

  # ---- describe/2 ------------------------------------------------------------

  describe "describe/2" do
    test "a port child leads its own process group; its start time comes from ps" do
      before = DateTime.utc_now() |> DateTime.add(-2, :second)
      {_port, os_pid} = open_sh("exec sleep 60")

      assert %{pid: ^os_pid, pgid: ^os_pid, started_at: %DateTime{} = started_at} =
               ProcessGroup.describe(os_pid)

      assert DateTime.compare(started_at, before) in [:gt, :eq]

      assert DateTime.compare(started_at, DateTime.add(DateTime.utc_now(), 2, :second)) ==
               :lt
    end

    test "parses ps's lstart (C locale, UTC), including a space-padded day" do
      ps = fake_ps(%{4242 => "  4242     1 Sat Nov  7 09:05:03 2026\n"})

      assert ProcessGroup.describe(4242, ps: ps) ==
               %{pid: 4242, pgid: 4242, started_at: ~U[2026-11-07 09:05:03Z]}
    end

    test "a process that is already gone keeps its own group, with no start time" do
      # Every port child leads its own group, so the post-exit reap can still
      # signal it; the boot sweep never acts on a group it cannot verify.
      assert ProcessGroup.describe(4242, ps: fake_ps(%{})) ==
               %{pid: 4242, pgid: 4242, started_at: nil}
    end

    test "a process in someone else's group records no group at all" do
      ps = fake_ps(%{4242 => "999 1 Sat Nov  7 09:05:03 2026\n"})

      assert %{pid: 4242, pgid: nil, started_at: ~U[2026-11-07 09:05:03Z]} =
               ProcessGroup.describe(4242, ps: ps, retries: 0)
    end

    test "unparseable ps output records no start time" do
      ps = fake_ps(%{4242 => "4242 1 yesterday-ish\n"})
      assert %{pid: 4242, pgid: 4242, started_at: nil} = ProcessGroup.describe(4242, ps: ps)
    end
  end

  # ---- kill/2 ----------------------------------------------------------------

  describe "kill/2" do
    test "kills the whole group, including a reparented child a tree walk cannot reach" do
      # The subshell exits at once, so its `sleep` is reparented to init: no
      # `pgrep -P` walk from the agent finds it. It is still in the group.
      {port, os_pid} =
        open_sh("(sleep 60 >/dev/null 2>&1 & echo $!); echo ready; exec sleep 60")

      orphan = int_line(port)
      assert line(port) == "ready"
      assert alive?(orphan)
      refute orphan in OsProcess.descendants(os_pid)

      assert ProcessGroup.kill(%{pid: os_pid, pgid: os_pid, started_at: nil}) == :ok

      refute alive?(orphan)
      refute alive?(os_pid)
      assert_receive {^port, {:exit_status, 137}}, 5_000
    end

    test "a group that no longer exists is :gone" do
      {port, os_pid} = open_sh("exit 0")
      assert_receive {^port, {:exit_status, 0}}, 5_000

      assert ProcessGroup.kill(os_pid) == :gone
    end

    test "never signals a group it does not know, or one that is not a worker's" do
      kill = recording_kill(self())
      self_pid = String.to_integer(System.pid())
      {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", System.pid()])
      own_pgid = out |> String.trim() |> String.to_integer()

      assert ProcessGroup.kill(%{pid: 4242, pgid: nil, started_at: nil}, kill: kill) == :gone
      assert ProcessGroup.kill(nil, kill: kill) == :gone

      for pgid <- [0, 1, -5, self_pid, own_pgid] do
        assert ProcessGroup.kill(pgid, kill: kill) == {:error, :unsafe_target}
      end

      refute_received {:kill, _}
    end
  end

  # ---- sweep/2 (boot) --------------------------------------------------------

  describe "sweep/2" do
    test "kills a recorded group whose leader is still the process the run spawned" do
      {leader, orphan} = OrphanedAgent.spawn!()
      group = ProcessGroup.describe(leader)
      assert group.pgid == leader

      assert [^group] = ProcessGroup.sweep([group])

      assert OrphanedAgent.gone?(leader)
      assert OrphanedAgent.gone?(orphan)
    end

    test "leaves a live process alone when its start time is not the recorded one (pid reuse)" do
      {leader, orphan} = OrphanedAgent.spawn!()
      %{started_at: started_at} = group = ProcessGroup.describe(leader)

      # The row says a process with this pid started an hour earlier: whatever
      # holds the pid now is not that process.
      reused = %{group | started_at: DateTime.add(started_at, -3_600, :second)}

      assert ProcessGroup.sweep([reused]) == []
      assert alive?(leader)
      assert alive?(orphan)
    end

    test "never kills an agent a running BEAM still owns (its parent is an erl_child_setup)" do
      # What a server booted against a copy of another install's database would
      # see: that install's live agents, recorded exactly. This BEAM is the other
      # install here; its port child is still parented by its `erl_child_setup`.
      {port, os_pid} =
        open_sh("(sleep 60 >/dev/null 2>&1 & echo $!); echo ready; exec sleep 60")

      orphan = int_line(port)
      assert line(port) == "ready"
      group = ProcessGroup.describe(os_pid)

      assert ProcessGroup.sweep([group]) == []
      assert alive?(os_pid)
      assert alive?(orphan)
    end

    test "asks for the leader's parent unless it is init, and skips one it cannot name" do
      test_pid = self()
      started_at = ~U[2026-11-07 09:05:03Z]

      ps =
        fake_ps(%{
          4242 => "4242 1 Sat Nov  7 09:05:03 2026\n",
          4343 => "4343 900 Sat Nov  7 09:05:03 2026\n",
          4444 => "4444 901 Sat Nov  7 09:05:03 2026\n",
          4545 => "4545 902 Sat Nov  7 09:05:03 2026\n"
        })

      comm = fn ppid ->
        send(test_pid, {:comm, ppid})

        case ppid do
          900 -> {"/usr/lib/erlang/erts-16.1/bin/erl_child_setup\n", 0}
          901 -> {"systemd\n", 0}
          902 -> {"", 1}
        end
      end

      groups =
        for pid <- [4242, 4343, 4444, 4545], do: %{pid: pid, pgid: pid, started_at: started_at}

      assert [%{pid: 4242}, %{pid: 4444}] =
               ProcessGroup.sweep(groups, ps: ps, comm: comm, kill: recording_kill(test_pid))

      refute_received {:comm, 1}
      assert_received {:kill, ["-KILL", "--", "-4242"]}
      assert_received {:kill, ["-KILL", "--", "-4444"]}
      refute_received {:kill, _}
    end

    test "tolerates a start time a few seconds off (Linux derives lstart from btime)" do
      ps = fake_ps(%{4242 => "4242 1 Sat Nov  7 09:05:05 2026\n"})
      group = %{pid: 4242, pgid: 4242, started_at: ~U[2026-11-07 09:05:03Z]}

      assert [^group] = ProcessGroup.sweep([group], ps: ps, kill: recording_kill(self()))
      assert_received {:kill, ["-KILL", "--", "-4242"]}
    end

    test "signals nothing for a leader that is gone, or one that no longer leads the group" do
      kill = recording_kill(self())
      started_at = ~U[2026-11-07 09:05:03Z]

      gone = %{pid: 4242, pgid: 4242, started_at: started_at}
      demoted = %{pid: 4343, pgid: 4343, started_at: started_at}
      ps = fake_ps(%{4343 => "777 1 Sat Nov  7 09:05:03 2026\n"})

      assert ProcessGroup.sweep([gone, demoted], ps: ps, kill: kill) == []
      refute_received {:kill, _}
    end

    test "skips a group it cannot verify: no start time, no group, not a leader's group" do
      test_pid = self()

      ps = fn pid ->
        send(test_pid, {:ps, pid})
        {"", 1}
      end

      kill = recording_kill(test_pid)

      unverifiable = [
        %{pid: 4242, pgid: 4242, started_at: nil},
        %{pid: 4242, pgid: nil, started_at: ~U[2026-11-07 09:05:03Z]},
        %{pid: 4242, pgid: 5151, started_at: ~U[2026-11-07 09:05:03Z]}
      ]

      assert ProcessGroup.sweep(unverifiable, ps: ps, kill: kill) == []
      refute_received {:ps, _}
      refute_received {:kill, _}
    end

    test "never kills the server's own process, whatever the row says" do
      self_pid = String.to_integer(System.pid())
      ps = fake_ps(%{self_pid => "#{self_pid} 1 Sat Nov  7 09:05:03 2026\n"})
      group = %{pid: self_pid, pgid: self_pid, started_at: ~U[2026-11-07 09:05:03Z]}

      assert ProcessGroup.sweep([group], ps: ps, kill: recording_kill(self())) == []
      refute_received {:kill, _}
    end
  end

  # ---- wrap/2 (the setsid wrapper and its group warden) ----------------------

  describe "wrap/2" do
    test "launches the agent through perl, leaving its argv, output and exit status alone" do
      args = sh_args("echo \"argv0=$0 args=$*\"; exit 7")
      args = %{args | argv: args.argv ++ ["a b", "c"]}

      wrapped = ProcessGroup.wrap(args, enabled: true)

      assert wrapped.exec == ProcessGroup.perl_path()
      assert [perl, "-e", _script, "--", "/bin/sh", "-c", _, "a b", "c"] = wrapped.argv
      assert perl == wrapped.exec
      assert wrapped.cd == "/"

      {port, _os_pid} = open_wrapped(wrapped)
      assert line(port) == "argv0=a b args=c"
      assert_receive {^port, {:exit_status, 7}}, 5_000
    end

    test "the agent leads its own process group" do
      {port, os_pid} =
        open_wrapped(ProcessGroup.wrap(sh_args("ps -o pid=,pgid= -p $$"), enabled: true))

      assert line(port) |> String.split() |> Enum.map(&String.to_integer/1) == [os_pid, os_pid]
    end

    test "the warden reaps what the agent left behind once the agent exits" do
      wrapped =
        ProcessGroup.wrap(sh_args("(sleep 60 >/dev/null 2>&1 & echo $!); exit 0"),
          enabled: true,
          warden_interval_s: 0.1
        )

      {port, _os_pid} = open_wrapped(wrapped)
      orphan = int_line(port)
      assert_receive {^port, {:exit_status, 0}}, 5_000

      # Nothing on this side signals it: the warden in the agent's group does.
      eventually(fn -> not alive?(orphan) end)
    end

    test "without the warden, what the agent left behind outlives it" do
      # The control for the test above.
      {port, _os_pid} = open_sh("(sleep 60 >/dev/null 2>&1 & echo $!); exit 0")
      orphan = int_line(port)
      assert_receive {^port, {:exit_status, 0}}, 5_000
      Process.sleep(300)
      assert alive?(orphan)
      kill_pid(orphan)
    end

    test "the warden does not hold the port open after the agent exits" do
      # A warden polling every 30 s that kept the port's stdout would hold the
      # exit back for 30 s.
      wrapped = ProcessGroup.wrap(sh_args("exit 3"), enabled: true, warden_interval_s: 30)
      {port, _os_pid} = open_wrapped(wrapped)

      assert_receive {^port, {:exit_status, 3}}, 5_000
    end

    test "a missing executable is left for Port.open to refuse, as before" do
      args = %{exec: "/nonexistent/agent", argv: ["/nonexistent/agent", "-p"], cd: "/"}
      assert ProcessGroup.wrap(args, enabled: true) == args
    end

    test "disabled, or with no perl, the spawn is untouched" do
      args = sh_args("exit 0")
      assert ProcessGroup.wrap(args, enabled: false) == args
      assert ProcessGroup.wrap(args, enabled: true, perl: nil) == args
    end
  end

  describe "warden_enabled?/0" do
    test "WARDMAST_WORKER_GROUP_WARDEN turns the wrapper off; config otherwise; on by default" do
      assert ProcessGroup.warden_enabled?(env: nil, config: nil)
      assert ProcessGroup.warden_enabled?(env: nil, config: true)
      refute ProcessGroup.warden_enabled?(env: nil, config: false)

      for off <- ~w(off OFF false 0 no disabled) do
        refute ProcessGroup.warden_enabled?(env: off, config: true)
      end

      assert ProcessGroup.warden_enabled?(env: "on", config: false)
    end
  end
end
