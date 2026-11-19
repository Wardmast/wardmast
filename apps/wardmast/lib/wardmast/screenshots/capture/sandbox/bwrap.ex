defmodule Wardmast.Screenshots.Capture.Sandbox.Bwrap do
  @moduledoc """
  The capture sandbox on a host: bubblewrap, no network, an allowlisted filesystem (bd-bhrsdv;
  `Wardmast.Screenshots.Capture.Sandbox` has the contract, the design is
  `docs/design/ui-screenshot-capture.md` §2).

  ## One app command

      bwrap --unshare-all --die-with-parent --new-session \\
        --ro-bind /usr /usr  (and /bin /sbin /lib* as the host has them: dir or symlink) \\
        --ro-bind /etc /etc \\
        --proc /proc --dev /dev --tmpfs /dev/shm --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp \\
        [--ro-bind-try <each screenshots.sandbox.readonly_paths entry>] \\
        [--tmpfs <mask dir> | --ro-bind /dev/null <server secret>] \\
        --bind <checkout> --bind <scratch> \\
        --chdir <checkout> -- <command>

  `--unshare-all` includes the network: the namespace has only its own `lo`, so the host's
  loopback (the coordinator on `:4848`, a database, other workers' servers) is an empty port and
  every other address has no route. Nothing of the host's home, `/tmp`, `/run` (the user's
  runtime sockets, the system bus), `/var` or `/opt` is there unless an operator lists it
  read-only. Whatever a listed path would show of the server itself is blanked: its secrets
  (`Wardmast.Worker.Jail.secret_files/0`), the control-socket dirs (`Jail.mask_paths/0`) and its
  own trees and sockets (`own_roots/0`: other workers' checkouts and egress sockets, the data
  home). The boot's checkout and scratch are bound after the masks, so they show even when one of
  their parents is masked.
  `--unshare-pid` hides the host's processes; `--die-with-parent` and the pid namespace take
  every process of a boot down with its bwrap.

  ## Reaching the app (`expose/2`)

  The app listens on `127.0.0.1:<port>` inside its own namespace, which the host cannot dial. So
  the host creates a **listening Unix socket** in a fresh `0700` directory under
  `Wardmast.Config.Paths.socket_root/0` (a small perl wrapper, run on the host before bwrap) and
  passes it in as fd 3; inside, a relay accepts on it and hands each connection to
  `socat - TCP:127.0.0.1:<port>`. The socket's directory is **not** mounted in the app's sandbox:
  the app can neither see the path nor swap the socket for a symlink that would turn the host's
  readiness probe into a request to some other host socket. The host reaches the app with
  `Req`'s `unix_socket:` (`reach/1`), so a redirect cannot send it anywhere else either.

  ## The browser (`browser/3`)

  Chromium runs in a sandbox of its own, built the same way, with only the shot's directory
  writable, the browser's install directory and the app's socket read-only, and a `socat`
  bridge from `127.0.0.1:<port>` to that socket, so the browser loads the same `base_url` the app
  was configured with and can reach nothing else. Chromium's own sandbox is off
  (`--no-sandbox`, see `Wardmast.Screenshots.Capture.Shooter.Chromium`): this one is the boundary.

  ## Availability (`status/0`)

  A real probe (`probe/0`): this module's own argv on a scratch dir must show only `lo`, no
  route, no file of the host beside the scratch dir, and a writable checkout. `bwrap`, `perl`,
  `socat` and `sh` must be installed, the last three inside the system directories (the sandbox
  runs them). A pass is cached until `reset/0`; a failure for a minute, so installing bwrap
  takes effect without a restart. Anything else is `{:error, reason}` and the capture is skipped.

  ## Config

    * `:capture_sandbox_available`: `true`/`false` forces the answer without probing (the test
      suite sets `false`).
    * `:capture_sandbox_bwrap`: the bwrap executable (default `:worker_jail_bwrap`, then `bwrap`
      on `PATH`).
    * `:capture_sandbox_probe_root`: where the probe makes its scratch dir (default under
      `Wardmast.Config.Paths.scratch_root/0`: disk-backed, and outside `/tmp`, so the canary
      the probe must not see is genuinely a host file).
  """

  @behaviour Wardmast.Screenshots.Capture.Sandbox

  alias Wardmast.Config.Paths
  alias Wardmast.Worker.Jail
  alias Wardmast.Worker.ReleaseEnv

  @system ~w(/usr /bin /sbin /lib /lib64 /lib32 /libx32)
  @private ~w(/tmp /run /var/tmp)
  @fontconfig ["/var/cache/fontconfig"]
  @probe_timeout_s 20
  @failure_ttl_ms 60_000
  # sun_path is 108 bytes on Linux; stay well under it.
  @max_socket_path 100

  # Runs on the host, before bwrap: create the listening socket and exec bwrap with it on fd 3.
  # `$^F = 3` keeps fd 3 open across the exec (perl marks every fd above $^F close-on-exec).
  @listen ~S"""
  BEGIN { $^F = 3 }
  use strict; use warnings; use Socket; use POSIX ();
  my $path = shift @ARGV;
  socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "capture sandbox: socket: $!\n";
  unlink $path;
  bind($s, pack_sockaddr_un($path)) or die "capture sandbox: bind $path: $!\n";
  listen($s, 128) or die "capture sandbox: listen: $!\n";
  if (fileno($s) != 3) { POSIX::dup2(fileno($s), 3) or die "capture sandbox: dup2: $!\n" }
  exec { $ARGV[0] } @ARGV or die "capture sandbox: exec $ARGV[0]: $!\n";
  """

  # Runs inside the app's sandbox: start the relay on fd 3, close fd 3, exec the app. The relay
  # keeps stderr (its own failure is worth the boot's tail) but not the app's stdout.
  @relay_sh ~S"""
  perl=$1 relay=$2 port=$3 socat=$4
  shift 4
  "$perl" -e "$relay" "$port" "$socat" >/dev/null &
  exec 3<&-
  exec "$@"
  """

  # The relay: each connection on the inherited listening socket goes to the app's port. socat's
  # complaints (the app not listening yet, during the readiness probe) are dropped so the app's
  # own output keeps the tail a boot failure reports.
  @relay ~S"""
  use strict; use warnings;
  my ($port, $socat) = @ARGV;
  open(my $listener, '<&=', 3) or die "capture relay: no listening socket on fd 3: $!\n";
  $SIG{CHLD} = 'IGNORE';
  while (1) {
    my $conn;
    unless (accept($conn, $listener)) { next if $!{EINTR}; die "capture relay: accept: $!\n" }
    my $pid = fork;
    if (defined $pid && $pid == 0) {
      close $listener;
      open(STDIN, '<&', $conn) or exit 1;
      open(STDOUT, '>&', $conn) or exit 1;
      open(STDERR, '>', '/dev/null');
      close $conn;
      exec { $socat } 'socat', '-', "TCP:127.0.0.1:$port" or exit 127;
    }
    close $conn;
  }
  """

  # Runs inside the browser's sandbox: 127.0.0.1:<port> -> the app's socket, up before the
  # browser starts (or exit 125, never a browser without its way to the app).
  @bridge_sh ~S"""
  socat=$1 sock=$2 port=$3
  shift 3
  "$socat" "TCP-LISTEN:$port,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$sock" >/dev/null 2>&1 &
  pid=$!
  hex=$(printf '%04X' "$port")
  i=0
  until grep -qi "^ *[0-9]*: 0100007F:$hex 00000000:0000 0A" /proc/net/tcp; do
    kill -0 "$pid" 2>/dev/null || { echo "capture sandbox: the browser's bridge exited at start-up" >&2; exit 125; }
    i=$((i + 1))
    if [ "$i" -ge 200 ]; then
      echo "capture sandbox: the browser's bridge on 127.0.0.1:$port did not come up" >&2
      exit 125
    fi
    sleep 0.05
  done
  exec "$@"
  """

  # bd-3glf2a. Runs inside an app command's sandbox, before the command: for each service, a relay
  # from 127.0.0.1:<port> to the service's socket (bound in read-only from the host), all up before
  # the command starts (or exit 125: a migration never runs against a missing database). The
  # relays never hold the app's inherited listening socket (fd 3).
  @services_sh ~S"""
  socat=$1
  shift
  relays=
  while [ "$#" -gt 1 ] && [ "$1" != "--" ]; do
    "$socat" "TCP-LISTEN:$1,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$2" </dev/null >/dev/null 2>&1 3<&- &
    relays="$relays $1:$!"
    shift 2
  done
  [ "$1" = "--" ] && shift
  for relay in $relays; do
    port=${relay%%:*}
    pid=${relay#*:}
    hex=$(printf '%04X' "$port")
    i=0
    until grep -qi "^ *[0-9]*: 0100007F:$hex 00000000:0000 0A" /proc/net/tcp; do
      kill -0 "$pid" 2>/dev/null || { echo "capture sandbox: the relay to the service on 127.0.0.1:$port exited at start-up" >&2; exit 125; }
      i=$((i + 1))
      if [ "$i" -ge 200 ]; then
        echo "capture sandbox: the relay to the service on 127.0.0.1:$port did not come up" >&2
        exit 125
      fi
      sleep 0.05
    done
  done
  exec "$@"
  """

  @probe_script ~S"""
  awk -F'[: ]+' 'NR>2 {print "if:" $2}' /proc/net/dev
  echo "routes:$(awk 'NR>1' /proc/net/route | wc -l)"
  if cat "$1" >/dev/null 2>&1; then echo canary:visible; else echo canary:hidden; fi
  if echo ok > "$2/write" 2>/dev/null; then echo write:ok; fi
  """

  @type tools :: %{bwrap: String.t(), perl: String.t(), socat: String.t(), sh: String.t()}
  @type host :: %{
          required(:tools) => tools(),
          required(:system) => [{String.t(), :dir | {:symlink, String.t()}}],
          required(:secret_files) => [String.t()],
          required(:mask_dirs) => [String.t()],
          optional(:resolv_conf) => String.t() | nil
        }

  # ── the contract ────────────────────────────────────────────────────────

  @impl true
  def status do
    case Application.get_env(:wardmast, :capture_sandbox_available) do
      true -> :ok
      false -> {:error, :disabled_by_config}
      _ -> cached_probe()
    end
  end

  @doc "Forget the cached probe result."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase({__MODULE__, :status})
    :ok
  end

  @impl true
  def describe({:tool_not_found, "bwrap", nil}), do: "bubblewrap (bwrap) is not installed"

  def describe({:tool_not_found, "bwrap", path}),
    do: "bubblewrap (bwrap) is not installed (looked for #{path})"

  def describe({:tool_not_found, name, _}),
    do: "#{name} is not installed, and the capture sandbox runs it"

  def describe({:tool_not_visible, name, path}),
    do: "#{name} (#{path}) is outside the system directories the capture sandbox shows"

  def describe({:netns_leaks, what}),
    do: "bwrap's network namespace is not isolated on this host (#{what})"

  def describe({:fs_leaks, what}), do: "the sandbox can read host files it must not (#{what})"

  def describe({:probe_failed, status, out}),
    do: "bwrap could not start the sandbox (exit #{status}): #{String.slice(out, 0, 500)}"

  def describe(:probe_timeout), do: "the sandbox probe timed out"

  def describe(:disabled_by_config),
    do: "sandboxing is turned off by `config :wardmast, :capture_sandbox_available, false`"

  def describe({:socket_path_too_long, path}),
    do: "the app's socket path is too long for a Unix socket (#{byte_size(path)} bytes: #{path})"

  def describe(other), do: inspect(other)

  @impl true
  def expose(_box, port) do
    root = Paths.socket_root()
    dir = Path.join(root, "cap-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower))
    socket = Path.join(dir, "s")

    with :ok <- short_enough(socket),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, %{port: port, socket: socket, dir: dir}}
    end
  end

  defp short_enough(path) when byte_size(path) <= @max_socket_path, do: :ok
  defp short_enough(path), do: {:error, {:socket_path_too_long, path}}

  @impl true
  def command(argv, box, app) do
    with {:ok, host} <- host(), do: {:ok, command_argv(argv, box, app, host)}
  end

  @impl true
  def fetch_command(argv, box) do
    with {:ok, host} <- host(), do: {:ok, fetch_argv(argv, box, host)}
  end

  @impl true
  def browser(argv, app, writable), do: browser(argv, app, writable, [])

  @impl true
  def browser([browser | args], app, writable, readonly) do
    with {:ok, host} <- host() do
      {:ok,
       browser_argv(
         [resolve_links(browser, 40) | args],
         app,
         writable,
         Enum.map(readonly, &shown_dir/1),
         host
       )}
    end
  end

  # What a read-only entry shows: the directory itself, or, for a file (a browser binary, perhaps
  # behind symlinks), the directory it really lives in.
  defp shown_dir(path) do
    resolved = resolve_links(path, 40)
    if File.dir?(resolved), do: resolved, else: Path.dirname(resolved)
  end

  @impl true
  def reach(%{socket: socket}) do
    # A pool per socket path, gone 30 s after the boot: one socket per boot would otherwise leave
    # an idle pool behind for every capture the server ever ran.
    [
      unix_socket: socket,
      finch: [pool_max_idle_time: 30_000, conn_opts: [transport_opts: [timeout: 2_000]]]
    ]
  end

  @impl true
  def release(%{dir: dir}) when is_binary(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  def release(_app), do: :ok

  # ── argv (pure: the host facts are an argument) ────────────────────────

  @doc false
  @spec command_argv([String.t()], map(), map() | nil, host()) :: [String.t()]
  def command_argv(argv, box, nil, host) do
    [host.tools.bwrap | sandbox_args(app_mounts(box), host)] ++
      ["--chdir", box.checkout, "--"] ++ services_prelude(box, host) ++ argv
  end

  def command_argv(argv, box, %{port: port, socket: socket}, host) do
    t = host.tools

    [t.perl, "-e", @listen, socket, t.bwrap | sandbox_args(app_mounts(box), host)] ++
      ["--chdir", box.checkout, "--"] ++
      services_prelude(box, host) ++
      [t.sh, "-c", @relay_sh, "sh", t.perl, @relay, Integer.to_string(port), t.socat | argv]
  end

  @doc false
  # bd-3glf2a: the deps cache seed. Trusted code only (a default-branch tree), so the one thing
  # it gets back is the network; the filesystem is an app command's.
  @spec fetch_argv([String.t()], map(), host()) :: [String.t()]
  def fetch_argv(argv, box, host) do
    mounts = app_mounts(box)
    mounts = %{mounts | system_try: mounts.system_try ++ List.wrap(Map.get(host, :resolv_conf))}

    [host.tools.bwrap | sandbox_args(mounts, host, network: true)] ++
      ["--chdir", box.checkout, "--" | argv]
  end

  # A relay per service (`@services_sh`) in front of the command, when the boot has services.
  defp services_prelude(box, host) do
    case Map.get(box, :services, []) do
      [] ->
        []

      services ->
        pairs = Enum.flat_map(services, &[Integer.to_string(&1.port), &1.socket])
        [host.tools.sh, "-c", @services_sh, "sh", host.tools.socat | pairs] ++ ["--"]
    end
  end

  @doc false
  @spec browser_argv([String.t()], map(), [String.t()], host()) :: [String.t()]
  def browser_argv(argv, app, writable, host), do: browser_argv(argv, app, writable, [], host)

  @doc false
  @spec browser_argv([String.t()], map(), [String.t()], [String.t()], host()) :: [String.t()]
  def browser_argv([browser | _] = argv, %{port: port, socket: socket}, writable, readonly, host) do
    t = host.tools
    visible = visible_roots(host)

    shown =
      [Path.dirname(browser) | readonly]
      |> Enum.reject(&under?(&1, visible))
      |> Enum.uniq()

    mounts = %{
      system_try: @fontconfig,
      readonly: [],
      ro: shown ++ [socket],
      ro_at: [],
      rw: Enum.uniq(writable)
    }

    [t.bwrap | sandbox_args(mounts, host)] ++
      ["--chdir", hd(writable), "--", t.sh, "-c", @bridge_sh, "sh", t.socat, socket] ++
      [Integer.to_string(port) | argv]
  end

  # bd-3glf2a: a boot's service sockets (`box.services`, each at its host path and, when the
  # config declares one, at its `sandbox_socket` path too) and the deps cache (`box.cache_dirs`)
  # are Wardmast's own files: read-only, and re-opened after the masks like the boot's own dirs.
  defp app_mounts(box) do
    services = Map.get(box, :services, [])

    %{
      system_try: [],
      readonly: box |> Map.get(:readonly_paths, []) |> Enum.map(&Path.expand/1) |> Enum.uniq(),
      ro: Enum.uniq(Enum.map(services, & &1.socket) ++ Map.get(box, :cache_dirs, [])),
      ro_at: for(%{sandbox_socket: at} = s <- services, is_binary(at), do: {s.socket, at}),
      rw: Enum.uniq([box.checkout, box.scratch])
    }
  end

  # Order matters. The private tmpfs mounts come before every bind (a checkout under /tmp must land
  # on top of the private /tmp, not under it). The masks come after the operator's read-only paths
  # (they hide what a listed path would show of the server's own files and sockets) and before
  # the boot's own binds, which re-open exactly their own paths: a mask over a parent of the
  # checkout cannot hide it, and nothing else of the masked tree comes back.
  # `network: true` is `fetch_argv/3`'s alone: trusted code fetching dependencies.
  defp sandbox_args(mounts, host, opts \\ []) do
    Enum.concat([
      ["--unshare-all"],
      if(Keyword.get(opts, :network, false), do: ["--share-net"], else: []),
      ["--die-with-parent", "--new-session"],
      system_args(host.system),
      ["--ro-bind", "/etc", "/etc"],
      Enum.flat_map(mounts.system_try, &["--ro-bind-try", &1, &1]),
      ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/dev/shm"],
      Enum.flat_map(@private, &["--tmpfs", &1]),
      Enum.flat_map(mounts.readonly, &["--ro-bind-try", &1, &1]),
      mask_args(mounts, host),
      Enum.flat_map(mounts.ro, &["--ro-bind", &1, &1]),
      Enum.flat_map(mounts.ro_at, fn {src, dest} -> ["--ro-bind", src, dest] end),
      Enum.flat_map(mounts.rw, &["--bind", &1, &1])
    ])
  end

  defp system_args(system) do
    Enum.flat_map(system, fn
      {path, :dir} -> ["--ro-bind", path, path]
      {path, {:symlink, target}} -> ["--symlink", target, path]
    end)
  end

  defp mask_args(mounts, host) do
    shown = system_roots(host) ++ mounts.readonly ++ mounts.ro ++ mounts.rw
    dirs = Enum.filter(host.mask_dirs, &under?(&1, shown))
    files = Enum.filter(host.secret_files, &under?(&1, shown))
    Enum.flat_map(dirs, &["--tmpfs", &1]) ++ Enum.flat_map(files, &["--ro-bind", "/dev/null", &1])
  end

  # The system dirs mounted from the host (what a mask can sit under)...
  defp system_roots(host) do
    for({path, :dir} <- host.system, do: path) ++ ["/etc"]
  end

  # ...and every path that resolves inside the sandbox, the symlinks of a merged /usr included.
  defp visible_roots(host) do
    for({path, _} <- host.system, do: path) ++ ["/etc"]
  end

  defp under?(path, roots),
    do: Enum.any?(roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  # ── the host ────────────────────────────────────────────────────────────

  @doc false
  @spec host() :: {:ok, host()} | {:error, term()}
  def host do
    system = system_layout()

    with {:ok, tools} <- tools(system) do
      {:ok,
       %{
         tools: tools,
         system: system,
         secret_files: Jail.secret_files(),
         mask_dirs: mask_dirs(),
         resolv_conf: resolv_conf()
       }}
    end
  end

  # The first place /etc/resolv.conf points to outside /etc (systemd-resolved's stub under /run):
  # the fetch sandbox binds it (bwrap follows the rest of the chain), or no name would resolve
  # there. `nil` when the file is in /etc (already shown).
  defp resolv_conf(path \\ "/etc/resolv.conf", hops \\ 10)
  defp resolv_conf(_path, 0), do: nil

  defp resolv_conf(path, hops) do
    case File.read_link(path) do
      {:ok, target} ->
        next = Path.expand(target, Path.dirname(path))
        if under?(next, ["/etc"]), do: resolv_conf(next, hops - 1), else: next

      {:error, _} ->
        nil
    end
  end

  @doc """
  The server's own trees and sockets: other workers' checkouts, scratch and logs, the egress and
  bridge sockets (connectable even through a read-only bind, and a way out of "no network"),
  the accounts' credentials and the data home with its database. None of them is ever shown, but
  a listed read-only path could contain one, so each is masked when it does.
  """
  @spec own_roots() :: [String.t()]
  def own_roots do
    Enum.map(
      [
        Paths.socket_root(),
        Paths.scratch_root(),
        Paths.worktree_root(),
        Paths.output_log_root(),
        Paths.sessions_root(),
        Paths.accounts_root(),
        Paths.preview_root(),
        Paths.memory_root(),
        Application.get_env(:wardmast, :data_dir, "~/.wardmast")
      ],
      &Path.expand/1
    )
  end

  # Jail's control-socket dirs plus the server's own roots, those that exist (bwrap cannot make a
  # mount point under a read-only bind, and an absent dir is no vector), outermost only.
  defp mask_dirs do
    dirs = (Jail.mask_paths() ++ own_roots()) |> Enum.filter(&File.dir?/1) |> Enum.uniq()
    Enum.reject(dirs, fn dir -> Enum.any?(dirs, &(&1 != dir and under?(dir, [&1]))) end)
  end

  defp system_layout do
    Enum.flat_map(@system, fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          [{path, :dir}]

        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(path) do
            {:ok, target} -> [{path, {:symlink, target}}]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  # bwrap runs on the host; perl, socat and sh also run inside, so they must be where the
  # sandbox shows the system.
  defp tools(system) do
    roots = for({path, _} <- system, do: path)

    with {:ok, bwrap} <- find_bwrap(),
         {:ok, perl} <- find_visible("perl", roots),
         {:ok, socat} <- find_visible("socat", roots),
         {:ok, sh} <- find_visible("sh", roots) do
      {:ok, %{bwrap: bwrap, perl: perl, socat: socat, sh: sh}}
    end
  end

  defp find_bwrap do
    configured =
      Application.get_env(:wardmast, :capture_sandbox_bwrap) ||
        Application.get_env(:wardmast, :worker_jail_bwrap)

    case configured do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, {:tool_not_found, "bwrap", path}}

      _ ->
        case System.find_executable("bwrap") do
          nil -> {:error, {:tool_not_found, "bwrap", nil}}
          path -> {:ok, path}
        end
    end
  end

  # The one on PATH when the sandbox shows it, else the system's own copy (a perlbrew perl first
  # on PATH does not hide /usr/bin/perl).
  defp find_visible(name, roots) do
    found =
      [System.find_executable(name), "/usr/bin/" <> name, "/bin/" <> name]
      |> Enum.filter(&(is_binary(&1) and File.regular?(&1)))
      |> Enum.uniq()

    case Enum.find(found, &under?(&1, roots)) do
      nil when found == [] -> {:error, {:tool_not_found, name, nil}}
      nil -> {:error, {:tool_not_visible, name, hd(found)}}
      path -> {:ok, path}
    end
  end

  # The browser's install dir is what the sandbox shows, so follow the links a launcher is
  # usually reached through (`/usr/bin/google-chrome` -> `/opt/google/chrome/google-chrome`).
  defp resolve_links(path, 0), do: path

  defp resolve_links(path, hops) do
    case File.read_link(path) do
      {:ok, target} -> resolve_links(Path.expand(target, Path.dirname(path)), hops - 1)
      {:error, _} -> path
    end
  end

  # ── the probe ───────────────────────────────────────────────────────────

  defp cached_probe do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :status}, nil) do
      :ok ->
        :ok

      {{:error, _} = error, at} when now - at < @failure_ttl_ms ->
        error

      _ ->
        result = probe()

        :persistent_term.put(
          {__MODULE__, :status},
          if(result == :ok, do: :ok, else: {result, now})
        )

        result
    end
  end

  @doc """
  Run the sandbox for real (uncached): this module's own argv around a small `sh` on a scratch
  dir must show only `lo` and no route, must not read a host file next to the scratch dir, and
  must write the scratch dir. `:ok` or `{:error, reason}`; never raises.
  """
  @spec probe() :: :ok | {:error, term()}
  def probe do
    with {:ok, host} <- host() do
      scratch =
        Path.join(probe_root(), "probe-#{System.pid()}-#{System.unique_integer([:positive])}")

      inside = Path.join(scratch, "inside")
      canary = Path.join([scratch, "outside", "canary"])

      try do
        :ok = File.mkdir_p(inside)
        :ok = File.mkdir_p(Path.dirname(canary))
        :ok = File.write(canary, "host only")

        [host.tools.sh, "-c", @probe_script, "sh", canary, inside]
        |> command_argv(%{checkout: inside, scratch: inside}, nil, host)
        |> run_bounded()
        |> judge_probe()
      rescue
        e -> {:error, {:probe_failed, :raised, Exception.message(e)}}
      after
        File.rm_rf(scratch)
      end
    end
  end

  @doc false
  @spec judge_probe(:timeout | {String.t(), integer()}) :: :ok | {:error, term()}
  def judge_probe(:timeout), do: {:error, :probe_timeout}

  def judge_probe({out, 0}) do
    lines = out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
    interfaces = for "if:" <> name <- lines, do: name
    routes = Enum.find(lines, &String.starts_with?(&1, "routes:"))

    cond do
      interfaces -- ["lo"] != [] ->
        {:error, {:netns_leaks, Enum.join(interfaces -- ["lo"], ", ")}}

      routes != "routes:0" ->
        {:error, {:netns_leaks, routes || "no route table"}}

      "canary:hidden" not in lines ->
        {:error, {:fs_leaks, "a host file beside the scratch dir"}}

      "lo" not in interfaces or "write:ok" not in lines ->
        {:error, {:probe_failed, 0, String.trim(out)}}

      true ->
        :ok
    end
  end

  def judge_probe({out, status}), do: {:error, {:probe_failed, status, String.trim(out)}}

  defp run_bounded([exe | args]) do
    {exe, args} =
      case System.find_executable("timeout") do
        nil -> {exe, args}
        timeout -> {timeout, ["-k", "5", Integer.to_string(@probe_timeout_s), exe | args]}
      end

    case ReleaseEnv.cmd(exe, args, stderr_to_stdout: true) do
      {_out, 124} -> :timeout
      result -> result
    end
  end

  defp probe_root do
    Application.get_env(:wardmast, :capture_sandbox_probe_root) ||
      Path.join(Paths.scratch_root(), "capture-sandbox-probe")
  end
end
