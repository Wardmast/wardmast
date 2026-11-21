defmodule Wardmast.Sessions.Naming do
  @moduledoc """
  The one place that knows how a session id maps to its OS-level handles
  (bd-bpt0ag, phase 1 of `docs/browser-hosted-coordinator-sessions.md`).

  Everything about a live session is **derivable from its id**:

      id           = "0197…"
      scope unit   = "arb-session-0197….scope"
      tmux socket  = "$XDG_RUNTIME_DIR/arbiter/session-0197….sock"
      tmux session = "coord"

  That is deliberate, and it is what makes restart survival cheap (§4.3):
  Wardmast holds no handle to the PTY, so after a restart it re-derives the
  unit name and socket path from the row rather than remembering a pid, a
  port, or a file descriptor. It is also what lets the adoption sweep run the
  mapping *backwards* — `session_id_from_unit/1` turns a unit name that
  `systemctl --user list-units 'arb-session-*'` printed back into the id to
  look up.

  The `.scope` suffix is carried in `scope_unit/1` because that is how
  `systemctl` prints it, and unit-name matching in the sweep is a string
  compare. `unit_arg/1` drops it again for `systemd-run --unit=`, matching the
  RFC §4.3 command shape literally.

  ## macOS (bd-a1pnnv, MAC P3-1)

  There is no systemd, so no scope: `Wardmast.Sessions.Runner.Darwin` stands a
  **pidfile** (`session-<id>.pid`, beside the socket) in for the scope unit.
  The unit *name* is kept as the session's stable handle — the row, the
  adoption sweep and `arb session list` all still speak `arb-session-<id>.scope`
  — and the Darwin runner answers `systemctl`-shaped questions about it from
  the pidfile + tmux.

  macOS also has no `XDG_RUNTIME_DIR`, and `$TMPDIR` (`/var/folders/xx/…/T/`)
  is so deep that `<TMPDIR>/arbiter/session-<uuid>.sock` overflows the 104-byte
  `sun_path` limit. The darwin socket dir is therefore
  `Wardmast.Config.Paths.socket_root/0` (`/tmp/arb-<hash>`) plus `/sessions`,
  and `socket_path/1` refuses — with
  `{:error, {:socket_path_too_long, path, max}}` — a path that would not fit,
  rather than letting `tmux` fail with an opaque "File name too long" at launch.
  """

  @unit_prefix "arb-session-"
  @socket_prefix "session-"
  @tmux_session "coord"
  @pipe_suffix ".out"
  @pid_suffix ".pid"

  # `sockaddr_un.sun_path` is 104 bytes on macOS/BSD (108 on Linux), NUL included.
  @darwin_sun_path 104

  @type socket_error ::
          :no_runtime_dir | {:socket_path_too_long, String.t(), pos_integer()}

  @doc """
  The prefix every session scope unit's name starts with. Also how
  `Wardmast.MCP.OperatorProof` recognizes a session's processes in their
  cgroup path (bd-8381tk).
  """
  @spec unit_prefix() :: String.t()
  def unit_prefix, do: @unit_prefix

  @doc "The `--unit=` argument for `systemd-run`, without the `.scope` suffix."
  @spec unit_arg(String.t()) :: String.t()
  def unit_arg(id) when is_binary(id), do: @unit_prefix <> id

  @doc "The full systemd unit name, as `systemctl` prints it."
  @spec scope_unit(String.t()) :: String.t()
  def scope_unit(id) when is_binary(id), do: unit_arg(id) <> ".scope"

  @doc "The glob `systemctl --user list-units` is given to enumerate session scopes."
  @spec unit_glob() :: String.t()
  def unit_glob, do: @unit_prefix <> "*"

  @doc """
  The session id inside a unit name, or `nil` when the name is not one of ours.

  Accepts the name with or without the `.scope` suffix, because `systemctl`
  output has been seen with both a bare name and a decorated one.
  """
  @spec session_id_from_unit(String.t()) :: String.t() | nil
  def session_id_from_unit(unit) when is_binary(unit) do
    with @unit_prefix <> rest <- String.trim(unit),
         id when id != "" <- String.trim_trailing(rest, ".scope") do
      id
    else
      _ -> nil
    end
  end

  @doc """
  Absolute path of the session's tmux socket.

  Lives under `$XDG_RUNTIME_DIR/arbiter/` — a tmpfs that is wiped on logout,
  which is the correct lifetime for a socket whose session cannot outlive the
  user manager anyway.
  """
  @spec socket_path(String.t()) :: {:ok, String.t()} | {:error, socket_error()}
  def socket_path(id) when is_binary(id) do
    with {:ok, dir} <- socket_dir() do
      check_socket_length(Path.join(dir, @socket_prefix <> id <> ".sock"))
    end
  end

  @doc """
  The host OS family as sessions see it: `config :wardmast, :sessions_os` (a
  test seam), else `:os.type/0`'s second element (`:darwin`, `:linux`, …).
  """
  @spec os() :: atom()
  def os do
    Application.get_env(:wardmast, :sessions_os) || elem(:os.type(), 1)
  end

  @doc """
  Longest usable Unix-socket path on this host, or `nil` where it is not
  enforced here. Only darwin is checked: its limit (104 with the NUL, so 103)
  is what the macOS port had to design around, and the darwin socket dir is
  ours to keep short.
  """
  @spec max_socket_bytes() :: pos_integer() | nil
  def max_socket_bytes do
    if os() == :darwin, do: @darwin_sun_path - 1, else: nil
  end

  defp check_socket_length(path) do
    case max_socket_bytes() do
      max when is_integer(max) and byte_size(path) > max ->
        {:error, {:socket_path_too_long, path, max}}

      _ ->
        {:ok, path}
    end
  end

  @doc """
  Socket path of a `:login` session (bd-98oj3s): `<socket_dir>/arb-login-<account>-<nonce>.sock`.

  Deliberately **not** `session-*.sock`, so the coordinator adoption sweep's
  glob, the orphan reaper and the operator's own tmux never see it. One socket
  (one tmux server) per login session, so ending one cannot take another's
  server down with its systemd scope.
  """
  @spec login_socket_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, socket_error()}
  def login_socket_path(id, account) when is_binary(id) and is_binary(account) do
    with {:ok, dir} <- socket_dir() do
      check_socket_length(Path.join(dir, login_name(account, id) <> ".sock"))
    end
  end

  @doc "`arb-login-<account>-<nonce>`: the tmux session name (and socket basename) of a login session."
  @spec login_name(String.t(), String.t()) :: String.t()
  def login_name(account, id) when is_binary(account) and is_binary(id) do
    slug =
      account
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 32)
      |> String.trim("-")

    nonce = id |> String.replace("-", "") |> String.slice(0, 8)
    "arb-login-#{slug}-#{nonce}"
  end

  @doc "The directory holding every session socket."
  @spec socket_dir() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def socket_dir do
    case runtime_dir() do
      {:xdg, dir} -> {:ok, Path.join(dir, "arbiter")}
      {:short, dir} -> {:ok, dir}
      nil -> {:error, :no_runtime_dir}
    end
  end

  @doc """
  Create the socket dir if needed and return it. On macOS the dir lives in
  world-writable `/tmp`, so it (and its `arb-<hash>` parent) is made `0700`:
  a tmux socket there must not be reachable by other users.
  """
  @spec ensure_socket_dir() ::
          {:ok, String.t()}
          | {:error, :no_runtime_dir | {:socket_dir_unavailable, String.t(), term()}}
  def ensure_socket_dir do
    with {:ok, dir} <- socket_dir(),
         :ok <- mkdir_private(dir, match?({:short, _}, runtime_dir())) do
      {:ok, dir}
    end
  end

  defp mkdir_private(dir, private?) do
    dirs = if private?, do: [Path.dirname(dir), dir], else: []

    with :ok <- File.mkdir_p(dir),
         :ok <- Enum.reduce_while(dirs, :ok, &chmod_step/2) do
      :ok
    else
      {:error, reason} -> {:error, {:socket_dir_unavailable, dir, reason}}
    end
  end

  defp chmod_step(d, :ok) do
    case File.chmod(d, 0o700) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc "Glob matching every session socket on this host."
  @spec socket_glob() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def socket_glob do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, @socket_prefix <> "*.sock")}
      error -> error
    end
  end

  @doc """
  Absolute path of the session's **pipe file** — the raw byte stream tmux's
  `pipe-pane` appends to and `Wardmast.Sessions.Stream` reads (phase 4).

  Beside the socket, in the same tmpfs, for the same reason: it is worthless
  once the user manager is gone. It is a plain file rather than a FIFO so that
  a reader which is not running (arbiter restarting, nobody attached) never
  blocks the pane's writer, and so `seq` can simply be a byte offset into it.
  """
  @spec pipe_path(String.t()) :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def pipe_path(id) when is_binary(id) do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, pipe_basename(id))}
      error -> error
    end
  end

  @doc "The pipe file's name, without a directory."
  @spec pipe_basename(String.t()) :: String.t()
  def pipe_basename(id) when is_binary(id), do: @socket_prefix <> id <> @pipe_suffix

  @doc """
  Absolute path of arbiter's own liveness heartbeat file (§4.6.3, phase 10).

  Beside the sockets, in the same tmpfs: `Wardmast.Sessions.Heartbeat` touches
  it while running, and every session's in-scope dead-man's switch
  (`Wardmast.Sessions.Provisioning`'s generated `watchdog.sh`) reads its mtime
  to decide whether arbiter is still around — the one mechanism that works if
  arbiter never comes back at all, because it needs no connection *to*
  arbiter, only a file arbiter used to be touching.
  """
  @spec heartbeat_path() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def heartbeat_path do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, heartbeat_basename())}
      error -> error
    end
  end

  @doc """
  Absolute path of the session's **pidfile** — macOS only (see the moduledoc).

  Two lines: the tmux server's pid, then the socket path. Written by
  `Wardmast.Sessions.Runner.Darwin` once the server is up; it is the darwin
  stand-in for "is the scope unit active" and is what lets a `stop` find the
  socket again without the session row.
  """
  @spec pid_path(String.t()) :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def pid_path(id) when is_binary(id) do
    case socket_dir() do
      {:ok, dir} -> {:ok, Path.join(dir, pid_basename(id))}
      error -> error
    end
  end

  @doc "The pidfile's name, without a directory."
  @spec pid_basename(String.t()) :: String.t()
  def pid_basename(id) when is_binary(id), do: @socket_prefix <> id <> @pid_suffix

  @doc "Glob matching every session pidfile on this host."
  @spec pid_glob() :: {:ok, String.t()} | {:error, :no_runtime_dir}
  def pid_glob do
    case socket_dir() do
      {:ok, dir} -> {:ok, pid_glob(dir)}
      error -> error
    end
  end

  @doc "Glob matching every session pidfile in `dir`."
  @spec pid_glob(String.t()) :: String.t()
  def pid_glob(dir) when is_binary(dir), do: Path.join(dir, @socket_prefix <> "*" <> @pid_suffix)

  @doc "The session id a pidfile path belongs to, or `nil`."
  @spec session_id_from_pidfile(String.t()) :: String.t() | nil
  def session_id_from_pidfile(path) when is_binary(path) do
    with @socket_prefix <> rest <- Path.basename(path),
         true <- String.ends_with?(rest, @pid_suffix),
         id when id != "" <- String.trim_trailing(rest, @pid_suffix) do
      id
    else
      _ -> nil
    end
  end

  @doc "The session id a socket path belongs to, or `nil`."
  @spec session_id_from_socket(String.t()) :: String.t() | nil
  def session_id_from_socket(path) when is_binary(path) do
    with @socket_prefix <> rest <- Path.basename(path),
         true <- String.ends_with?(rest, ".sock"),
         id when id != "" <- String.trim_trailing(rest, ".sock") do
      id
    else
      _ -> nil
    end
  end

  @doc """
  The tmux session name inside the socket — a constant.

  One tmux session per socket, always called `coord`, so `§4.7`'s documented
  fallback (`tmux -S … attach -t coord`) is a fixed string an operator can
  type from memory when Wardmast is down.
  """
  @spec tmux_session() :: String.t()
  def tmux_session, do: @tmux_session

  @doc """
  The tmux session name for a particular row: `arb-login-<account>-<nonce>` for
  a `:login` session (bd-98oj3s), otherwise the constant `coord`.
  """
  @spec tmux_session(map()) :: String.t()
  def tmux_session(%{kind: :login, login_account: account, id: id}) when is_binary(account),
    do: login_name(account, id)

  def tmux_session(_session), do: @tmux_session

  # Keyed by the deploy data home so a second server on the same host (another
  # port, scratch HOME/DB) never touches — or masks — the live server's file.
  defp heartbeat_basename do
    key =
      :sha256
      |> :crypto.hash(data_home())
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "heartbeat-" <> key
  end

  defp data_home, do: Wardmast.Env.data_home()

  # `XDG_RUNTIME_DIR` is set for every systemd user session, which is the only
  # environment a session can launch in (`systemd-run --user` needs the user
  # manager anyway). Config override exists so a test can point the socket dir
  # at a tmp_dir without exporting a var into the whole VM.
  #
  # macOS has no `XDG_RUNTIME_DIR` (and no systemd user session to want it), so
  # there the socket dir falls back to the short `/tmp/arb-<hash>/sessions`.
  defp runtime_dir do
    case Application.get_env(:wardmast, :sessions_runtime_dir) ||
           System.get_env("XDG_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" ->
        {:xdg, dir}

      _ ->
        if os() == :darwin,
          do: {:short, Path.join(Wardmast.Config.Paths.socket_root(), "sessions")},
          else: nil
    end
  end
end
