defmodule Wardmast.Sessions.Runner.Darwin do
  @moduledoc """
  The macOS `Wardmast.Sessions.Runner` (bd-a1pnnv, MAC P3-1; design D3): detached
  tmux sessions with no `systemd-run`, liveness by tmux + a pidfile.

  ## Why a translation layer

  Everything that touches a session — `Wardmast.Sessions` (launch, kill),
  `Wardmast.Sessions.Adoption` (boot sweep), `Wardmast.Sessions.OrphanReaper`
  — already talks to the OS through the one `Runner.run/3` seam, in a fixed
  vocabulary: `systemd-run … tmux …` to start, `systemctl --user list-units` to
  enumerate, `systemctl --user stop <unit>` to end, plain `tmux` for the rest.
  macOS has neither systemd command, and the *behaviour* contract does not
  change, so this module implements the same three verbs on top of tmux and
  `ps`, and delegates everything else (`tmux` itself) untouched. Adoption,
  orphan reaping and the heartbeat therefore work on macOS through the
  unchanged lifecycle code — only the runner underneath differs — and
  `Wardmast.Sessions.runner/1` picks this module by default on darwin.

  ## How each verb maps

    * `systemd-run --user --scope … --unit=arb-session-<id> tmux …` — the scope
      flags are dropped and `tmux … new-session -d …` runs directly. The tmux
      **server** daemonizes itself (`setsid`, new session and process group), so
      it is not in the server's process group: neither launchd's group kill nor
      the P2-1 group reap (`MAC P2-1`) reaches it, and a session survives a
      restart of `com.wardmast.server` exactly as a scope survives a restart of
      `wardmast.service`. After a successful start the tmux server's pid
      (`display-message -p` of tmux's `pid` format) and the socket path are written to the
      session's pidfile (`Wardmast.Sessions.Naming.pid_path/1`).
    * `systemctl --user list-units arb-session-*` — one `systemctl`-shaped line
      per pidfile whose pid is alive **and is still a tmux** (`ps -o comm=`;
      a recycled pid is not a session). A pidfile whose process is gone is
      stale and removed. If `ps` itself cannot be run the answer is a *failure*,
      never an empty list: the adoption sweep must not conclude the host is
      empty because it could not look (`Adoption`'s "failure is not everything
      died" rule).
    * `systemctl --user stop <unit>` — `tmux kill-server` on the socket from the
      pidfile, then `SIGTERM` to the pid if it is still a live tmux, then the
      pidfile is removed. Exact pid and exact socket from the file — never a
      pattern match. An unknown unit is non-zero ("not loaded"), like systemctl.

  Liveness is deliberately two-signal, as on Linux: `Adoption` keeps a row on
  *either* a live pidfile **or** a socket that answers `tmux has-session`, so a
  launch that failed to record a pid (see below) is still adopted by its socket.

  ## Limits

  A scope stop kills every process in the cgroup; there is no cgroup here. The
  tmux server's `SIGHUP` on `kill-server` reaches each pane's session leader,
  which is how an agent CLI exits, but a deliberately `nohup`-ed grandchild
  survives a stop. A server pid that cannot be read after a successful launch
  is logged and skipped rather than failing the launch — the session is up, and
  the tmux-socket signal still covers it.

  ## Test seam

  The real work is delegated to `config :wardmast, :sessions_darwin_inner_runner`
  (default `Wardmast.Sessions.Runner.Host`, i.e. the scrubbed `ReleaseEnv.cmd/3`
  spawn site), so this module itself spawns nothing and holds no handle
  (`Wardmast.Sessions.NoPtyHandleTest`).
  """

  @behaviour Wardmast.Sessions.Runner

  alias Wardmast.Sessions.Naming
  alias Wardmast.Sessions.Runner

  require Logger

  @impl Wardmast.Sessions.Runner
  def run("systemd-run", args, opts), do: launch(args, opts)
  def run("systemctl", ["--user", "list-units" | _], _opts), do: list_units()
  def run("systemctl", ["--user", "stop", unit | _], _opts), do: stop(unit)
  def run(command, args, opts), do: inner().run(command, args, opts)

  # -- launch -----------------------------------------------------------------

  defp launch(args, opts) do
    {flags, rest} = Enum.split_while(args, &String.starts_with?(&1, "--"))

    case rest do
      [command | command_args] ->
        case inner().run(command, command_args, opts) do
          {_out, 0} = ok ->
            record_pidfile(unit_flag(flags), command_args)
            ok

          failed ->
            failed
        end

      [] ->
        {"systemd-run: no command to run\n", 2}
    end
  end

  defp unit_flag(flags) do
    Enum.find_value(flags, fn
      "--unit=" <> unit -> unit
      _ -> nil
    end)
  end

  defp record_pidfile(unit, command_args) do
    with unit when is_binary(unit) <- unit,
         id when is_binary(id) <- Naming.session_id_from_unit(unit),
         socket when is_binary(socket) <- socket_arg(command_args),
         {:ok, pid} <- server_pid(socket) do
      path = Path.join(Path.dirname(socket), Naming.pid_basename(id))
      write_pidfile(path, pid, socket)
    else
      _ ->
        Logger.warning(
          "Wardmast.Sessions.Runner.Darwin: no pidfile recorded for #{inspect(unit)}; " <>
            "the session stays discoverable through its tmux socket only"
        )
    end
  end

  defp socket_arg(args) do
    case Enum.drop_while(args, &(&1 != "-S")) do
      ["-S", socket | _] -> socket
      _ -> nil
    end
  end

  # The `pid` format variable is the tmux *server's* pid, which is what outlives every client.
  defp server_pid(socket) do
    case inner().run("tmux", ["-S", socket, "display-message", "-p", "\#{pid}"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> parse_pid(out)
      _ -> :error
    end
  end

  defp write_pidfile(path, pid, socket) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, "#{pid}\n#{socket}\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        Logger.warning(
          "Wardmast.Sessions.Runner.Darwin: cannot write #{path}: #{inspect(reason)}"
        )
    end
  end

  # -- list-units -------------------------------------------------------------

  defp list_units do
    case Naming.pid_glob() do
      {:ok, glob} -> glob |> Path.wildcard() |> Enum.sort() |> collect_live([])
      {:error, :no_runtime_dir} -> {"", 0}
    end
  end

  defp collect_live([], acc), do: {acc |> Enum.reverse() |> Enum.join(), 0}

  defp collect_live([path | rest], acc) do
    with id when is_binary(id) <- Naming.session_id_from_pidfile(path),
         {:ok, pid, _socket} <- read_pidfile(path) do
      case alive_tmux?(pid) do
        :alive ->
          line = "#{Naming.scope_unit(id)} loaded active running tmux server pid #{pid}\n"
          collect_live(rest, [line | acc])

        :dead ->
          File.rm(path)
          collect_live(rest, acc)

        {:error, output, status} ->
          {output, status}
      end
    else
      _ ->
        # Unparseable or foreign: not a pidfile we can reason about.
        collect_live(rest, acc)
    end
  end

  # -- stop -------------------------------------------------------------------

  defp stop(unit) do
    with id when is_binary(id) <- Naming.session_id_from_unit(unit),
         {:ok, path} <- Naming.pid_path(id),
         {:ok, pid, socket} <- read_pidfile(path) do
      _ = inner().run("tmux", ["-S", socket, "kill-server"], stderr_to_stdout: true)

      if alive_tmux?(pid) == :alive do
        _ = inner().run("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      File.rm(path)
      {"", 0}
    else
      _ -> {"Failed to stop #{unit}: Unit #{unit} not loaded.\n", 5}
    end
  end

  # -- shared -----------------------------------------------------------------

  defp read_pidfile(path) do
    with {:ok, contents} <- File.read(path),
         [pid_line, socket | _] <- String.split(contents, "\n", trim: true),
         {:ok, pid} <- parse_pid(pid_line) do
      {:ok, pid, socket}
    else
      _ -> :error
    end
  end

  defp parse_pid(text) do
    case Integer.parse(String.trim(text)) do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> :error
    end
  end

  # `ps -p` exits 1 for "no such process"; anything else non-zero means ps
  # itself misbehaved, which must not be read as "dead".
  defp alive_tmux?(pid) do
    case inner().run("ps", ["-p", Integer.to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
      {out, 0} -> if String.contains?(out, "tmux"), do: :alive, else: :dead
      {_out, 1} -> :dead
      {out, status} -> {:error, out, status}
    end
  rescue
    e in ErlangError -> {:error, "could not run ps: #{inspect(e.original)}\n", 127}
  end

  defp inner, do: Application.get_env(:wardmast, :sessions_darwin_inner_runner, Runner.Host)
end
