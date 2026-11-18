defmodule Wardmast.MCP.OperatorProofDarwinTest do
  @moduledoc """
  `Wardmast.MCP.OperatorProof.authorize/2` on macOS (bd-5tg348). There is no
  `/proc` and no cgroup, so the ancestry walk (check 2) asks `ps`, and the
  session check (check 4) finds each session's tmux server through
  `Wardmast.Sessions.Runner.Darwin`'s pidfiles.

  The policy cases pass `os: :darwin` and an injected process table
  (`Wardmast.Test.FakePs`), so they run on any host. The real-process cases at
  the bottom use this VM as the "server" and the host's own `/bin/ps`. They are
  not tagged `:linux`: procps answers the same queries on Linux, and the macOS
  CI job runs them against BSD `ps`.
  """
  use ExUnit.Case, async: true

  alias Wardmast.MCP.OperatorProof
  alias Wardmast.Sessions.Naming
  alias Wardmast.Test.FakePs

  @moduletag :tmp_dir

  @uid 501
  @server 500
  @session "0197abcd-0000-7000-8000-000000000001"

  # pid => {ppid, comm}
  @tree %{
    1 => {0, "/sbin/launchd"},
    # the Wardmast server (a launchd agent) and what it spawned
    @server => {1, "/Users/op/.wardmast/current/erts-16.1/bin/beam.smp"},
    501 => {@server, "/Users/op/.wardmast/current/erts-16.1/bin/erl_child_setup"},
    502 => {501, "/opt/homebrew/bin/claude"},
    # a worker's double-forked orphan, reparented to launchd: no cgroup
    # remembers where it came from
    503 => {1, "/bin/sh"},
    # a Wardmast session: Runner.Darwin's tmux server daemonized under launchd
    700 => {1, "/opt/homebrew/bin/tmux"},
    701 => {700, "-zsh"},
    702 => {701, "/opt/homebrew/bin/claude"},
    # the operator's terminal
    600 => {1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"},
    601 => {600, "login"},
    602 => {601, "-zsh"}
  }

  setup %{tmp_dir: dir} do
    write_pidfile!(dir, @session, 700)
    {:ok, dir: dir, opts: opts(dir)}
  end

  defp opts(dir, table \\ @tree, ps_opts \\ []) do
    [
      os: :darwin,
      ps: FakePs.runner(table, ps_opts),
      session_dir: dir,
      server_uid: @uid,
      server_pid: @server
    ]
  end

  # Runner.Darwin's format: the tmux server's pid, then the socket path.
  defp write_pidfile!(dir, id, pid) do
    File.write!(
      Path.join(dir, Naming.pid_basename(id)),
      "#{pid}\n#{Path.join(dir, "session-#{id}.sock")}\n"
    )
  end

  defp peer(pid, uid \\ @uid), do: %{pid: pid, uid: uid, gid: 20}

  # The pids a field was asked about, in order, from FakePs's messages.
  defp asked(field) do
    receive do
      {:fake_ps, args} ->
        pid = args |> Enum.drop_while(&(&1 != "-p")) |> Enum.at(1) |> String.to_integer()
        if field in args, do: [pid | asked(field)], else: asked(field)
    after
      0 -> []
    end
  end

  describe "check 2: ancestry, walked with ps" do
    test "the operator's terminal passes", %{opts: opts} do
      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert :ok = OperatorProof.authorize(peer(600), opts)
    end

    test "a process the server spawned (a worker, its tools) is refused", %{opts: opts} do
      assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(501), opts)
      assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(502), opts)
    end

    test "the server process itself is refused", %{opts: opts} do
      assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(@server), opts)
    end

    test "walks one pid at a time with `ps -o ppid= -p <pid>`, up to launchd", %{opts: opts} do
      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert asked("ppid=") == [602, 601, 600]
    end

    # The documented macOS limit: with no cgroup there is no check 3, so an
    # orphan launchd adopted is indistinguishable from the operator's shell.
    test "a double-forked orphan reparented to launchd gets past it", %{opts: opts} do
      assert :ok = OperatorProof.authorize(peer(503), opts)
    end

    test "a deep but finite chain passes", %{dir: dir} do
      assert :ok = OperatorProof.authorize(peer(2000), opts(dir, chain(2000, 200)))
    end
  end

  describe "check 4: sessions, found through Runner.Darwin's pidfiles" do
    test "a process below a live session's tmux server is refused", %{opts: opts} do
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(701), opts)
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(702), opts)
    end

    test "the session's tmux server itself is refused", %{opts: opts} do
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(700), opts)
    end

    test "liveness is the pidfile's pid still being a tmux, as Runner.Darwin judges it",
         %{opts: opts} do
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(702), opts)
      assert asked("comm=") == [700]
    end

    test "a pidfile whose pid now belongs to something else does not refuse the operator",
         %{dir: dir, opts: opts} do
      # 601 is the operator's `login`, reusing a dead session's pid
      write_pidfile!(dir, "0197abcd-0000-7000-8000-00000000dead", 601)

      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(702), opts)
    end

    test "files that are not readable session pidfiles are skipped, as the runner skips them",
         %{dir: dir, opts: opts} do
      File.write!(Path.join(dir, "heartbeat-abc"), "602\n")
      File.write!(Path.join(dir, "session-#{@session}.sock"), "")
      File.write!(Path.join(dir, Naming.pid_basename("garbage")), "not-a-pid\n/x.sock\n")

      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert {:error, :in_session_scope} = OperatorProof.authorize(peer(702), opts)
    end

    test "a session with no pidfile is not recognized: the pidfile is the record", %{dir: dir} do
      opts = opts(Path.join(dir, "no-sessions-here"))
      assert :ok = OperatorProof.authorize(peer(702), opts)
    end

    test "a peer outside every session is not asked about", %{opts: opts} do
      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert asked("comm=") == []
    end
  end

  describe "check 1: the same Unix user" do
    test "a different Unix user is refused before anything is walked", %{opts: opts} do
      assert {:error, :foreign_uid} = OperatorProof.authorize(peer(602, 502), opts)
      assert asked("ppid=") == []
    end

    test "the server's uid defaults to what ps reports for this VM's own pid", %{dir: dir} do
      own = String.to_integer(System.pid())
      table = Map.put(@tree, own, {1, "beam.smp"})
      opts = dir |> opts(table, uid: @uid) |> Keyword.delete(:server_uid)

      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert own in asked("uid=")
      assert {:error, :foreign_uid} = OperatorProof.authorize(peer(602, 0), opts)
    end

    test "a server uid ps cannot report fails closed", %{dir: dir} do
      override = fn
        "uid=", _pid -> {"", 1}
        _field, _pid -> nil
      end

      opts = dir |> opts(@tree, override: override) |> Keyword.delete(:server_uid)
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(602), opts)
    end
  end

  describe "every failure fails closed" do
    test "a peer pid ps does not know (the process is gone)", %{opts: opts} do
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(9999), opts)
    end

    test "a pid of 0, or a negative one, is an unknown peer", %{opts: opts} do
      assert {:error, :unknown_peer} = OperatorProof.authorize(peer(0), opts)
      assert {:error, :unknown_peer} = OperatorProof.authorize(peer(-1), opts)
    end

    test "an ancestor that cannot be read mid-walk", %{dir: dir} do
      opts = opts(dir, Map.delete(@tree, 600))
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(602), opts)
    end

    test "ps itself failing", %{dir: dir} do
      opts = opts(dir, @tree, override: fn _field, _pid -> {"ps: boom\n", 71} end)
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(602), opts)
    end

    test "ps that cannot be run at all", %{opts: opts} do
      raising = fn _args -> raise ErlangError, original: :enoent end
      enoent = Keyword.put(opts, :ps, raising)
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(602), enoent)

      not_found = Keyword.put(opts, :ps, fn _args -> {"", 127} end)
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(602), not_found)
    end

    test "output that is not a single pid", %{dir: dir} do
      for garbage <- ["", "\n", "garbage\n", "601 600\n", "601\n600\n", "-3\n", "6o1\n"] do
        override = fn
          "ppid=", 601 -> {garbage, 0}
          _field, _pid -> nil
        end

        assert {:error, :peer_unreadable} =
                 OperatorProof.authorize(peer(602), opts(dir, @tree, override: override)),
               "accepted ps output #{inspect(garbage)}"
      end
    end

    test "a cycle in the parent chain", %{dir: dir} do
      table = Map.merge(@tree, %{800 => {801, "a"}, 801 => {802, "b"}, 802 => {800, "c"}})
      assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(800), opts(dir, table))
      # caught at the repeat, not by running into the depth limit
      assert asked("ppid=") == [800, 801, 802]

      self_parented = Map.put(@tree, 803, {803, "d"})

      assert {:error, :peer_unreadable} =
               OperatorProof.authorize(peer(803), opts(dir, self_parented))
    end

    test "a chain deeper than the walk's limit", %{dir: dir} do
      assert {:error, :peer_unreadable} =
               OperatorProof.authorize(peer(2000), opts(dir, chain(2000, 300)))
    end

    test "a session server whose command cannot be read", %{dir: dir} do
      for failure <- [{"", 1}, {"ps: boom\n", 71}, {"", 0}] do
        override = fn
          "comm=", 700 -> failure
          _field, _pid -> nil
        end

        assert {:error, :peer_unreadable} =
                 OperatorProof.authorize(peer(702), opts(dir, @tree, override: override)),
               "accepted #{inspect(failure)} for the session server's command"
      end
    end
  end

  describe "the darwin mechanism is the darwin one" do
    test "it never reads a /proc root, even when given one", %{opts: opts} do
      opts = Keyword.put(opts, :proc_root, "/nonexistent-proc")
      assert :ok = OperatorProof.authorize(peer(602), opts)
      assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(502), opts)
    end
  end

  describe "parse_local_peercred/2" do
    test "decodes a version-0 struct xucred and the LOCAL_PEERPID int" do
      assert OperatorProof.parse_local_peercred(xucred(501, [20, 12, 61]), <<4242::native-32>>) ==
               {:ok, %{pid: 4242, uid: 501, gid: 20}}
    end

    test "anything else is :error" do
      good = xucred(501, [20])
      pid = <<4242::native-32>>

      assert OperatorProof.parse_local_peercred(binary_part(good, 0, 72), pid) == :error
      assert OperatorProof.parse_local_peercred(good <> <<0::32>>, pid) == :error
      assert OperatorProof.parse_local_peercred(xucred(501, [20], version: 1), pid) == :error
      assert OperatorProof.parse_local_peercred(xucred(501, []), pid) == :error
      assert OperatorProof.parse_local_peercred(xucred(501, [20], ngroups: 17), pid) == :error
      assert OperatorProof.parse_local_peercred(good, <<1, 2>>) == :error
    end
  end

  describe "real processes through the host's ps (this VM plays the server)" do
    setup %{dir: dir} do
      {:ok, real: [os: :darwin, session_dir: Path.join(dir, "no-sessions-here")]}
    end

    test "a child process of this VM is refused", %{real: real} do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

      {:os_pid, child} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", [Integer.to_string(child)]) end)

      assert {:error, :spawned_by_arbiter} =
               OperatorProof.authorize(%{pid: child, uid: own_uid(), gid: 0}, real)
    end

    test "this VM itself is refused", %{real: real} do
      own = String.to_integer(System.pid())

      assert {:error, :spawned_by_arbiter} =
               OperatorProof.authorize(%{pid: own, uid: own_uid(), gid: 0}, real)
    end

    test "this VM's parent, outside its tree, passes", %{real: real} do
      {out, 0} = System.cmd("ps", ["-o", "ppid=", "-p", System.pid()])
      parent = out |> String.trim() |> String.to_integer()

      assert :ok = OperatorProof.authorize(%{pid: parent, uid: own_uid(), gid: 0}, real)
    end
  end

  # parent-to-child links from `first` down `n` levels: first -> first+1 -> … -> 1
  defp chain(first, n) do
    last = first + n - 1

    Map.new(first..last, fn pid ->
      {pid, {if(pid == last, do: 1, else: pid + 1), "sh"}}
    end)
    |> Map.put(1, {0, "/sbin/launchd"})
  end

  defp xucred(uid, groups, opts \\ []) do
    version = Keyword.get(opts, :version, 0)
    ngroups = Keyword.get(opts, :ngroups, length(groups))
    padded = groups ++ List.duplicate(0, 16 - length(groups))

    <<version::native-unsigned-32, uid::native-unsigned-32, ngroups::native-signed-16, 0::16>> <>
      for g <- padded, into: <<>>, do: <<g::native-unsigned-32>>
  end

  defp own_uid do
    {out, 0} = System.cmd("id", ["-u"])
    out |> String.trim() |> String.to_integer()
  end
end
