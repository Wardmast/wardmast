defmodule Wardmast.MCP.OperatorProof do
  @moduledoc """
  Who may mint a coordinator token without already holding one (bd-8381tk).

  Workers, reviewers and sessions run on the same host **and as the same Unix
  user** as the operator, so neither "the request came from loopback" nor
  "the file is mode 0600" tells the operator apart from a worker. What does
  differ is *where the process came from*: everything Wardmast runs is started
  by the server's own BEAM, while the operator's shell is not.

  `Wardmast.MCP.OperatorSocket` accepts connections on a Unix domain socket,
  reads the kernel-attested peer credentials (`SO_PEERCRED`: pid, uid, gid,
  recorded at `connect()` time and not forgeable by the client; macOS uses
  other sources, see "macOS" below), and asks `authorize/2` whether that peer
  is the operator:

    1. **Same Unix user as the server.** Any other uid is refused. (The socket
       file is also mode 0600 in a 0700 directory, so another user can't
       connect in the first place.)
    2. **Not descended from the server.** The peer's parent chain is walked
       through `/proc/<pid>/stat`. If it reaches the server's own OS pid, the
       peer is a worker, reviewer or session, or something one of them
       started, and is refused. The server itself is refused too.
    3. **Not inside the server's service cgroup.** When the server runs as a
       systemd unit (its cgroup ends in `.service`, like the release's
       `wardmast.service`), every process it spawns inherits that cgroup. That
       includes a double-forked orphan that has been reparented to
       `systemd --user` and so escaped check 2. A peer in that cgroup, or
       below it, is refused. A dev server run from a terminal shares the
       terminal's scope with the operator's shell, so this check is skipped
       there and only check 2 applies.
    4. **Not inside an Wardmast session's scope.** Interactive sessions
       (coordinator, refine, login) are launched by
       `systemd-run --user --scope --unit=arb-session-<id>` running a tmux
       server that daemonizes. Their processes therefore descend from
       `systemd --user`, not the server, and sit in a sibling cgroup of
       `wardmast.service`, so checks 2 and 3 both miss them. A peer whose
       cgroup path has a segment starting with
       `Wardmast.Sessions.Naming.unit_prefix/0` is refused. This check runs
       whether or not the server has a service cgroup (dev servers launch
       sessions the same way).

  Anything unreadable fails closed: a peer whose `/proc` entry disappears
  mid-walk, a pid of 0, a Linux host without `/proc`.

  ## macOS (bd-5tg348)

  macOS has no `SO_PEERCRED`, no `/proc` and no cgroups, so `authorize/2`
  applies the same policy through other sources (`os: :darwin`):

    * **Peer credentials.** `LOCAL_PEERCRED` (a `struct xucred`, see
      `parse_local_peercred/2`) gives the uid as of `connect()`, and
      `LOCAL_PEERPID` gives the pid.
    * **Check 1** compares that uid with the server's effective uid, which
      `ps -o uid=` reports for the server's own pid.
    * **Check 2** walks the parent chain one pid at a time with
      `/bin/ps -o ppid= -p <pid>`, up to launchd (pid 1). Reaching the
      server's pid, or starting there, is `:spawned_by_arbiter`, as on Linux.
    * **There is no check 3.** A worker's double-forked orphan is reparented
      to launchd, and nothing like a cgroup records where it came from, so
      it gets past check 2. This is the main gap on macOS.
    * **Check 4** has no scope to look for. Instead it reads the tmux server
      pids that `Wardmast.Sessions.Runner.Darwin` records in each session's
      pidfile (`Runner.Darwin.recorded_server_pids/1`). A chain that passes
      through one of them, while that pid still runs a tmux, is
      `:in_session_scope`. A recorded pid that now runs something else was
      reused and does not count.

  Each of these fails closed with `:peer_unreadable`: a pid `ps` doesn't
  know, a `ps` that fails, can't be run or prints anything but one number, a
  cycle in the chain, and a chain deeper than 256.

  ## What this does and does not stop

  A jailed worker (agy under `Wardmast.Worker.Jail`) cannot reach the socket
  at all: its directory sits under `/run/user/<uid>`, which the jail blanks,
  and the jail masks the fallback directory too. It also can't escape
  `wardmast.service` through `systemd-run --user`, because the session bus is
  masked. An **unjailed** worker (Claude today) is refused on the paths it
  would actually take: `arb mcp token mint`, `curl` to the HTTP route, a
  script that connects to the socket. But it runs as the operator with full
  host access, so it could still escape deliberately with
  `systemd-run --user --scope` or by moving itself to another cgroup. For
  such a worker this is a guardrail, not a hard boundary. The same holds for
  an Wardmast session's processes (check 4): they are unjailed, so one that
  re-launches itself into another unit on purpose gets past the check. On
  macOS the guardrail is weaker still: a double fork is enough to get past
  check 2, and a session process that double-forks, or deletes its
  session's pidfile, gets past check 4. See docs/worker-security.md,
  "Operator proof for token minting".
  """

  alias Wardmast.Sessions.Naming
  alias Wardmast.Sessions.Runner.Darwin

  @type peer :: %{pid: integer(), uid: integer(), gid: integer()}
  @type reason ::
          :foreign_uid
          | :unknown_peer
          | :peer_unreadable
          | :spawned_by_arbiter
          | :in_arbiter_cgroup
          | :in_session_scope

  # Deeper than any real process tree; bounds either walk (/proc, or ps on
  # macOS) against a parent loop.
  @max_depth 256

  @doc """
  `:ok` if `peer` is the operator, `{:error, reason}` otherwise.

  Options (all default to the running VM's own values; overridden by tests):

    * `:server_pid`: the server's OS pid (`System.pid/0`)
    * `:server_uid`: the server's uid
    * `:server_cgroup`: the server's dedicated service cgroup, or `nil` to skip
      check 3 (`dedicated_cgroup/1` of `/proc/self/cgroup`). Check 4 runs
      either way.
    * `:proc_root`: `"/proc"`
    * `:os`: which inspection to use, `:darwin` (`ps` and session pidfiles,
      see "macOS" above) or anything else (`/proc` and cgroups). Defaults to
      the host's, except that passing a `:proc_root` selects `/proc`.
    * `:ps` (darwin): `fn args -> {output, exit_status} end` standing in for
      `/bin/ps`
    * `:session_dir` (darwin): where `Wardmast.Sessions.Runner.Darwin` keeps
      its session pidfiles (`Wardmast.Sessions.Naming.socket_dir/0`)
  """
  @spec authorize(peer(), keyword()) :: :ok | {:error, reason()}
  def authorize(%{pid: _, uid: _} = peer, opts \\ []) do
    if darwin?(opts), do: authorize_darwin(peer, opts), else: authorize_proc(peer, opts)
  end

  defp authorize_proc(%{pid: pid, uid: uid}, opts) do
    proc = Keyword.get(opts, :proc_root, "/proc")
    server_uid = Keyword.get_lazy(opts, :server_uid, &own_uid/0)
    server_pid = Keyword.get_lazy(opts, :server_pid, fn -> String.to_integer(System.pid()) end)

    cond do
      uid != server_uid ->
        {:error, :foreign_uid}

      not is_integer(pid) or pid <= 0 ->
        {:error, :unknown_peer}

      true ->
        with :ok <- check_ancestry(proc, pid, server_pid, 0),
             {:ok, peer_cgroup} <- peer_cgroup(proc, pid),
             :ok <- check_session_scope(peer_cgroup) do
          server_cgroup = Keyword.get_lazy(opts, :server_cgroup, fn -> own_cgroup(proc) end)
          check_service_cgroup(peer_cgroup, server_cgroup)
        end
    end
  end

  @doc "Operator-facing text for a refusal reason."
  @spec describe(reason() | atom()) :: String.t()
  def describe(:foreign_uid), do: "the connecting process belongs to a different Unix user"

  def describe(:spawned_by_arbiter),
    do:
      "the connecting process was started by the Wardmast server (a worker, reviewer or " <>
        "session, or something one of them ran); those get their tokens at dispatch"

  def describe(:in_arbiter_cgroup),
    do:
      "the connecting process is inside the Wardmast server's service cgroup, where every " <>
        "worker it spawns runs"

  def describe(:in_session_scope),
    do:
      "the connecting process is inside a Wardmast session (its systemd scope, or below its " <>
        "tmux server on macOS); a session uses the token the server minted for it at provisioning"

  def describe(:peer_unreadable),
    do:
      "the connecting process could not be inspected (through /proc on Linux, ps on macOS), " <>
        "so it is refused"

  def describe(:unknown_peer), do: "the kernel reported no process for the connection"

  def describe(:no_peercred),
    do: "the kernel did not report the connecting process's pid and uid, so it is refused"

  def describe(other), do: "refused (#{inspect(other)})"

  # ---- socket location ---------------------------------------------------

  @doc """
  Directory the operator socket lives in: `/run/user/<uid>/arbiter` when the
  host has a per-user runtime dir (systemd hosts; the agy jail blanks it),
  else `<data home>/run` (see `run_dir/0`; default `~/.wardmast/run`), which
  `Wardmast.Worker.Jail.mask_paths/0` masks explicitly through this function. `ARB_OPERATOR_SOCKET` overrides the whole path, see
  `socket_path/1`.

  Both the server and the `arb` CLI derive the path the same way from the
  uid, never from `XDG_RUNTIME_DIR`, so a shell that lacks the variable
  still finds the socket.
  """
  @spec socket_dir() :: String.t()
  def socket_dir do
    case System.get_env("ARB_OPERATOR_SOCKET") do
      path when is_binary(path) and path != "" -> Path.dirname(Path.expand(path))
      _ -> default_dir()
    end
  end

  @doc "The operator socket path for the server listening on HTTP `port`."
  @spec socket_path(non_neg_integer()) :: String.t()
  def socket_path(port) when is_integer(port) do
    case System.get_env("ARB_OPERATOR_SOCKET") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(default_dir(), "operator-#{port}.sock")
    end
  end

  @doc "Longest usable Unix domain socket path in bytes: macOS `sun_path` is 104 including the NUL (103 usable), Linux 108 (107); the smaller keeps one limit valid on both."
  @spec max_socket_path_bytes() :: pos_integer()
  def max_socket_path_bytes, do: 103

  defp default_dir do
    runtime = own_uid() && "/run/user/#{own_uid()}"

    if runtime && File.dir?(runtime) do
      Path.join(runtime, "arbiter")
    else
      run_dir()
    end
  end

  @doc """
  Fallback runtime dir `<data home>/run`, the data home being
  `Wardmast.Env.data_home/0` (the one resolver the release env, the jail and
  the CLI share). `ARB_HOME` is the source checkout, not the data home, so it
  is deliberately ignored. `WardmastCli.OperatorSocket` calls the same
  resolver so the client finds the socket without the server's env.
  """
  @spec run_dir() :: String.t()
  def run_dir, do: Path.join(Wardmast.Env.data_home(), "run")

  # ---- helpers -------------------------------------------------------------

  @doc "Decode a Linux `struct ucred` (the `SO_PEERCRED` payload)."
  @spec parse_peercred(binary()) :: {:ok, peer()} | :error
  def parse_peercred(<<pid::native-signed-32, uid::native-signed-32, gid::native-signed-32>>),
    do: {:ok, %{pid: pid, uid: uid, gid: gid}}

  def parse_peercred(_), do: :error

  @doc """
  Decode macOS's peer credentials: the `LOCAL_PEERCRED` payload (a
  version-0 `struct xucred`: `u_int` version, `uid_t` uid, `short` ngroups,
  then `gid_t` groups[16] at offset 12, 76 bytes; groups[0] is the effective
  gid) and the `LOCAL_PEERPID` payload (the peer's pid as an `int`).
  """
  @spec parse_local_peercred(binary(), binary()) :: {:ok, peer()} | :error
  def parse_local_peercred(
        <<0::native-unsigned-32, uid::native-unsigned-32, ngroups::native-signed-16, _::16,
          gid::native-unsigned-32, _more_groups::binary-size(60)>>,
        <<pid::native-signed-32>>
      )
      when ngroups in 1..16,
      do: {:ok, %{pid: pid, uid: uid, gid: gid}}

  def parse_local_peercred(_xucred, _peerpid), do: :error

  @doc """
  The server's cgroup path from the contents of `/proc/<pid>/cgroup` when it
  is a dedicated systemd service (last segment ends in `.service`), else
  `nil`. Prefers the unified (v2) hierarchy and falls back to v1's
  `name=systemd` line.
  """
  @spec dedicated_cgroup(String.t()) :: String.t() | nil
  def dedicated_cgroup(contents) do
    case cgroup_path(contents) do
      path when is_binary(path) ->
        if String.ends_with?(path, ".service"), do: path, else: nil

      nil ->
        nil
    end
  end

  defp cgroup_path(contents) do
    entries =
      contents
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&cgroup_entry/1)

    unified = Enum.find_value(entries, fn {id, c, p} -> id == "0" and c == "" and p end)
    v1 = Enum.find_value(entries, fn {_id, c, p} -> c == "name=systemd" and p end)

    cond do
      is_binary(unified) and unified != "/" -> unified
      is_binary(v1) -> v1
      true -> unified
    end
  end

  defp cgroup_entry(line) do
    case String.split(line, ":", parts: 3) do
      [id, controllers, path] -> [{id, controllers, path}]
      _ -> []
    end
  end

  defp check_ancestry(_proc, pid, server_pid, _depth) when pid == server_pid,
    do: {:error, :spawned_by_arbiter}

  defp check_ancestry(_proc, pid, _server_pid, _depth) when pid in [0, 1], do: :ok

  defp check_ancestry(_proc, _pid, _server_pid, depth) when depth > @max_depth,
    do: {:error, :peer_unreadable}

  defp check_ancestry(proc, pid, server_pid, depth) do
    case ppid(proc, pid) do
      {:ok, parent} -> check_ancestry(proc, parent, server_pid, depth + 1)
      :error -> {:error, :peer_unreadable}
    end
  end

  # `/proc/<pid>/stat` is "pid (comm) state ppid …"; comm may itself contain
  # spaces and ")", so split after the *last* ")".
  defp ppid(proc, pid) do
    with {:ok, stat} <- File.read(Path.join([proc, Integer.to_string(pid), "stat"])),
         [_, _ | _] = parts <- String.split(stat, ")"),
         [_state, ppid | _] <- parts |> List.last() |> String.split(),
         {n, ""} <- Integer.parse(ppid) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  # The peer's cgroup path, or nil when the file has no usable line. An
  # unreadable file fails closed.
  defp peer_cgroup(proc, pid) do
    case File.read(Path.join([proc, Integer.to_string(pid), "cgroup"])) do
      {:ok, contents} -> {:ok, cgroup_path(contents)}
      {:error, _} -> {:error, :peer_unreadable}
    end
  end

  defp check_session_scope(nil), do: :ok

  defp check_session_scope(peer_cgroup) do
    prefix = Naming.unit_prefix()

    if peer_cgroup |> String.split("/") |> Enum.any?(&String.starts_with?(&1, prefix)),
      do: {:error, :in_session_scope},
      else: :ok
  end

  defp check_service_cgroup(_peer_cgroup, nil), do: :ok

  defp check_service_cgroup(peer_cgroup, server_cgroup) do
    if peer_cgroup == server_cgroup or
         (is_binary(peer_cgroup) and String.starts_with?(peer_cgroup, server_cgroup <> "/")),
       do: {:error, :in_arbiter_cgroup},
       else: :ok
  end

  defp own_cgroup(proc) do
    case File.read(Path.join([proc, "self", "cgroup"])) do
      {:ok, contents} -> dedicated_cgroup(contents)
      {:error, _} -> nil
    end
  end

  defp own_uid do
    case File.stat("/proc/self") do
      {:ok, %{uid: uid}} -> uid
      _ -> nil
    end
  end

  # ---- darwin (bd-5tg348) ----------------------------------------------------

  # `:os` when given. Otherwise a `:proc_root`, the /proc walk's own seam,
  # selects /proc on any host, and the host decides the rest.
  defp darwin?(opts) do
    case Keyword.fetch(opts, :os) do
      {:ok, os} -> os == :darwin
      :error -> not Keyword.has_key?(opts, :proc_root) and match?({:unix, :darwin}, :os.type())
    end
  end

  defp authorize_darwin(%{pid: pid, uid: uid}, opts) do
    ps = Keyword.get(opts, :ps, &run_ps/1)
    server_pid = Keyword.get_lazy(opts, :server_pid, &own_pid/0)

    with {:ok, server_uid} <- darwin_server_uid(opts, ps),
         :ok <- check_peer(pid, uid, server_uid),
         {:ok, chain} <- ps_walk(ps, pid, server_pid, [], 0) do
      servers = Darwin.recorded_server_pids(Keyword.get(opts, :session_dir))
      check_session_servers(ps, chain, servers)
    end
  end

  # The VM's effective uid, as `ps` reports it for its own pid (no /proc to
  # stat). The same uid `LOCAL_PEERCRED` reports for a peer.
  defp darwin_server_uid(opts, ps) do
    case Keyword.fetch(opts, :server_uid) do
      {:ok, uid} -> {:ok, uid}
      :error -> with :error <- ps_int(ps, "uid=", own_pid()), do: {:error, :peer_unreadable}
    end
  end

  defp check_peer(_pid, uid, server_uid) when uid != server_uid, do: {:error, :foreign_uid}

  defp check_peer(pid, _uid, _server_uid) when not is_integer(pid) or pid <= 0,
    do: {:error, :unknown_peer}

  defp check_peer(_pid, _uid, _server_uid), do: :ok

  # Check 2 on darwin: the peer and its ancestors, nearest first, up to (not
  # including) launchd or the kernel. Reaching the server's pid is a refusal.
  # A pid met twice is a cycle, and a parent that can't be read, at any depth,
  # fails closed, as does a chain deeper than @max_depth.
  defp ps_walk(_ps, pid, server_pid, _chain, _depth) when pid == server_pid,
    do: {:error, :spawned_by_arbiter}

  defp ps_walk(_ps, pid, _server_pid, chain, _depth) when pid in [0, 1],
    do: {:ok, Enum.reverse(chain)}

  defp ps_walk(_ps, _pid, _server_pid, _chain, depth) when depth > @max_depth,
    do: {:error, :peer_unreadable}

  defp ps_walk(ps, pid, server_pid, chain, depth) do
    with false <- pid in chain,
         {:ok, parent} <- ps_int(ps, "ppid=", pid) do
      ps_walk(ps, parent, server_pid, [pid | chain], depth + 1)
    else
      _ -> {:error, :peer_unreadable}
    end
  end

  # Check 4 on darwin: refuse a chain that passes through a session's tmux
  # server. A recorded pid that no longer runs a tmux was reused and is not a
  # session (Runner.Darwin judges liveness the same way). One whose command
  # can't be read fails closed.
  defp check_session_servers(ps, chain, servers) do
    chain
    |> Enum.filter(&(&1 in servers))
    |> Enum.reduce_while(:ok, fn pid, :ok ->
      case ps_comm(ps, pid) do
        {:ok, comm} ->
          if Darwin.tmux_command?(comm),
            do: {:halt, {:error, :in_session_scope}},
            else: {:cont, :ok}

        :error ->
          {:halt, {:error, :peer_unreadable}}
      end
    end)
  end

  # One header-less number, `ps -o <field> -p <pid>`. Anything but exit 0 with
  # exactly one non-negative integer is :error.
  defp ps_int(ps, field, pid) do
    with {out, 0} <- call_ps(ps, ["-o", field, "-p", Integer.to_string(pid)]),
         {n, ""} when n >= 0 <- Integer.parse(String.trim(out)) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  # The process's command, as Runner.Darwin's liveness check reads it. `-ww`
  # so a narrow COLUMNS in the server's env can't truncate it.
  defp ps_comm(ps, pid) do
    case call_ps(ps, ["-ww", "-o", "comm=", "-p", Integer.to_string(pid)]) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          comm -> {:ok, comm}
        end

      _ ->
        :error
    end
  end

  # A `ps` that raises (it can't be spawned, say) is a failed read, never a pass.
  defp call_ps(ps, args) do
    ps.(args)
  rescue
    _ -> {"", 127}
  end

  # `/bin/ps` by absolute path, not through PATH. The server's PATH comes from
  # the operator's shell (captured into wardmast.env) and can lead with a
  # directory the same uid can write, Homebrew's for one, where a planted `ps`
  # could vouch for any ancestry. `/bin` is on macOS's sealed system volume.
  defp run_ps(args), do: System.cmd("/bin/ps", args, env: [{"LC_ALL", "C"}])

  defp own_pid, do: String.to_integer(System.pid())
end
