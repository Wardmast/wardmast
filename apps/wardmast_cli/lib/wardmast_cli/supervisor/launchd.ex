defmodule WardmastCli.Supervisor.Launchd do
  @moduledoc """
  `WardmastCli.Supervisor` backend for macOS/launchd: with `Supervisor.Systemd`
  one of only two modules in the CLI that spawn a service-manager executable
  (here `launchctl`).

  It manages one launchd job (`com.wardmast.server`) in one of two shapes: the
  free single-developer **LaunchAgent** (per-user, `gui/<uid>` domain) or, on a
  shared team Mac, a system-wide **LaunchDaemon** (`/Library/LaunchDaemons`,
  `system` domain, `UserName` = a dedicated service account, started at boot).
  `service_mode/0` tells them apart from which plist is on disk, and every call
  below targets the one that is installed. The job runs a dev checkout (agent
  only) or a release install (`<data-home>/current/bin/wardmast start`) via an
  env-sourcing wrapper (see `Launchd.Plist`). It sits under the same restart/health state machine
  as systemd, with these mappings:

    * restart  — `launchctl kickstart -k`: kill + start in one synchronous
      step. There is no `--no-block` equivalent and no `InvocationID`;
      `service_info/0` reports `invocation_id: ""`, which the caller reads as
      "no baseline", so a `running` job right after kickstart counts as the new
      instance. A job that is not loaded is `bootstrap`ped from its plist.
    * stop     — `launchctl bootout`: with `KeepAlive` a plain kill would be
      respawned, so stopping means unloading the job.
    * install  — `launchctl bootstrap` + `enable`; there is no daemon-reload.
    * state    — `launchctl print`: exit 0 is managed, 113 / "Could not find
      service" is not.

  Not available, reported rather than faked: logrotate timers and
  `arb-session-*` scopes (a systemd concept). A LaunchAgent starts at login;
  for start-at-boot use the LaunchDaemon (`arb install service --system`).
  """

  @behaviour WardmastCli.Supervisor

  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Cmd.Start
  alias WardmastCli.Output
  alias WardmastCli.SessionSockets
  alias WardmastCli.Supervisor.Launchd.Plist

  @not_loaded ~r/Could not find service|No such process|not find specified service/i

  # ---- service probe / lifecycle (arb restart) -------------------------------

  @impl true
  def service_state do
    case launchctl(["print", target()]) do
      {_out, 0} ->
        :managed

      {out, code} ->
        cond do
          # Installed but not loaded (after `bootout` or a failed bootstrap) is
          # still ours, like a stopped systemd unit: `restart_service/0`
          # bootstraps it from the plist.
          not_loaded?(out, code) and File.exists?(plist_path()) -> :managed
          not_loaded?(out, code) -> :not_found
          true -> {:unreachable, "launchctl exited #{code}: #{String.trim(out)}"}
        end
    end
  rescue
    e in ErlangError ->
      # launchctl is not installed (Linux, minimal container): there is no
      # launchd to be in charge. Anything else is "could not ask".
      if e.original == :enoent,
        do: :not_found,
        else: {:unreachable, "could not run launchctl: #{inspect(e.original)}"}
  end

  @doc "Directory the plist is written to (`~/Library/LaunchAgents`); `:bd2_launchd_dir` seam for tests."
  @spec plist_dir() :: Path.t()
  def plist_dir do
    case Process.get(:bd2_launchd_dir) do
      dir when is_binary(dir) -> dir
      _ -> Path.join([System.user_home!(), "Library", "LaunchAgents"])
    end
  end

  @doc "Directory of the system-wide LaunchDaemon plist; `:bd3_launchd_daemon_dir` seam for tests."
  @spec daemon_dir() :: Path.t()
  def daemon_dir do
    case Process.get(:bd3_launchd_daemon_dir) do
      dir when is_binary(dir) -> dir
      _ -> Plist.daemon_dir()
    end
  end

  @doc "Log directory of the LaunchDaemon; `:bd3_launchd_log_dir` seam for tests."
  @spec daemon_log_dir() :: Path.t()
  def daemon_log_dir do
    case Process.get(:bd3_launchd_log_dir) do
      dir when is_binary(dir) -> dir
      _ -> Plist.daemon_log_dir()
    end
  end

  @doc "Path of the per-user LaunchAgent plist."

  @spec agent_plist_path() :: Path.t()
  def agent_plist_path, do: Path.join(plist_dir(), Plist.file_name())

  @doc "Path of the system-wide LaunchDaemon plist."
  @spec daemon_plist_path() :: Path.t()
  def daemon_plist_path, do: Path.join(daemon_dir(), Plist.file_name())

  @doc "Full path of the installed service's plist (the daemon's when one is installed)."
  @spec plist_path() :: Path.t()
  def plist_path, do: plist_path(active_scope())

  @doc "The plist path for `scope` (`:user` = LaunchAgent, `:system` = LaunchDaemon)."
  @spec plist_path(:user | :system) :: Path.t()
  def plist_path(:user), do: agent_plist_path()
  def plist_path(:system), do: daemon_plist_path()

  @doc """
  Which launchd shape is installed, read from the plists on disk (never from
  `launchctl`, so it works unprivileged and with the job unloaded):

    * `:mode` — `:agent`, `:daemon`, `:both` (a conflict: two servers, one
      port) or `:none`
    * `:plist` — the installed plist (the daemon's when both exist), or `nil`
    * `:user` / `:group` — the daemon's `UserName` / `GroupName`; `user: nil`
      for a daemon plist means launchd would run it as **root**
    * `:owner_uid` / `:file_mode` — the daemon plist's owner and permission
      bits (launchd refuses a daemon plist that is not root-owned or is
      group/world-writable)
  """
  @spec service_mode() :: %{
          mode: :agent | :daemon | :both | :none,
          plist: Path.t() | nil,
          user: String.t() | nil,
          group: String.t() | nil,
          owner_uid: non_neg_integer() | nil,
          file_mode: non_neg_integer() | nil
        }
  def service_mode do
    base = %{plist: nil, user: nil, group: nil, owner_uid: nil, file_mode: nil}

    case {File.exists?(agent_plist_path()), File.exists?(daemon_plist_path())} do
      {false, false} -> Map.put(base, :mode, :none)
      {true, false} -> base |> Map.put(:plist, agent_plist_path()) |> Map.put(:mode, :agent)
      {false, true} -> daemon_info(base, :daemon)
      {true, true} -> daemon_info(base, :both)
    end
  end

  defp daemon_info(base, mode) do
    path = daemon_plist_path()

    xml =
      case File.read(path) do
        {:ok, body} -> body
        _ -> ""
      end

    {owner_uid, file_mode} =
      case File.stat(path) do
        {:ok, st} -> {st.uid, Bitwise.band(st.mode, 0o777)}
        _ -> {nil, nil}
      end

    base
    |> Map.merge(%{
      mode: mode,
      plist: path,
      user: plist_string(xml, "UserName"),
      group: plist_string(xml, "GroupName"),
      owner_uid: owner_uid,
      file_mode: file_mode
    })
  end

  defp plist_string(xml, key) do
    case Regex.run(~r{<key>#{key}</key>\s*<string>([^<]*)</string>}, xml) do
      [_, value] ->
        value
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&amp;", "&")

      _ ->
        nil
    end
  end

  # A daemon, once installed, is the service `arb restart` / `arb stop` mean.
  defp active_scope do
    if File.exists?(daemon_plist_path()), do: :system, else: :user
  end

  @impl true
  def unit_dirs, do: [plist_dir(), daemon_dir()]

  @impl true
  def unit_file_name, do: Plist.file_name()

  @impl true
  def stop_service do
    case launchctl(["bootout", target()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        if not_loaded?(out, code), do: :ok, else: {:error, failed("bootout", out, code)}
    end
  rescue
    e in ErlangError -> {:error, "could not run launchctl: #{inspect(e.original)}"}
  end

  # `kickstart -k` returns once the replacement is started, so there is no
  # queued job to poll for — the caller's await sees `running` straight away.
  @impl true
  def restart_service do
    if active_scope() == :system and not root?() do
      # launchd answers a non-root kickstart of the system domain with a bare
      # "Operation not permitted"; say what to do instead.
      {:error, "restarting the system-wide LaunchDaemon needs root",
       "Run `#{restart_cmd()}` (or `sudo ward restart`)."}
    else
      kickstart()
    end
  rescue
    e in ErlangError ->
      {:error, "could not run launchctl: #{inspect(e.original)}",
       "Ensure launchctl is on your PATH."}
  end

  defp kickstart do
    case launchctl(["kickstart", "-k", target()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        if not_loaded?(out, code), do: bootstrap_unloaded(), else: kickstart_failed(out, code)
    end
  end

  # The job was stopped (`bootout`) or never loaded: load it from its plist,
  # which starts it (`RunAtLoad`).
  defp bootstrap_unloaded do
    if File.exists?(plist_path()) do
      case launchctl(["bootstrap", domain(), plist_path()]) do
        {_out, 0} ->
          :ok

        {out, code} ->
          {:error, "launchctl bootstrap #{domain()} #{plist_path()} failed (exit #{code})",
           "Output:\n" <> String.trim_trailing(out)}
      end
    else
      {:error, "#{Plist.label()} is not loaded and #{plist_path()} does not exist",
       "Run `arb install service` to install it."}
    end
  end

  defp kickstart_failed(out, code) do
    {:error, "launchctl kickstart -k #{target()} failed (exit #{code})",
     "Output:\n" <> String.trim_trailing(out)}
  end

  # `state = running` is active; any other loaded state (waiting, spawn
  # scheduled, exited) is not. There is no InvocationID or queued job.
  @impl true
  def service_info do
    case launchctl(["print", target()]) do
      {out, 0} -> parse_info(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_info(out) do
    case Regex.run(~r/^\s*state = (\S+)/m, out) do
      [_, "running"] -> %{state: "active", invocation_id: "", job: nil}
      [_, _other] -> %{state: "inactive", invocation_id: "", job: nil}
      _ -> nil
    end
  end

  @impl true
  def recover_stuck_service do
    _ = launchctl(["bootout", target()])

    if File.exists?(plist_path()), do: launchctl(["bootstrap", domain(), plist_path()])
    _ = launchctl(["kickstart", "-k", target()])
    :ok
  rescue
    e in ErlangError ->
      Start.log_text("recovery failed: #{inspect(e.original)}")
      :ok
  end

  # ---- session scopes (arb session list) -------------------------------------

  # launchd has no transient scopes: a macOS coordinator session is a detached
  # tmux server recorded in a pidfile (`Wardmast.Sessions.Runner.Darwin`, MAC
  # P3-1). Rendered in `systemctl list-units` columns so `arb session list`
  # parses both the same way. A pid that is not (or no longer) a tmux is a
  # stale pidfile; `ps` itself failing is an error, never "no sessions".
  @impl true
  def list_scopes(prefix) do
    SessionSockets.pidfiles()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, pid}, {:ok, acc} ->
      case tmux_alive(pid) do
        :alive ->
          {:cont,
           {:ok, ["#{prefix}#{id}.scope loaded active running tmux server pid #{pid}\n" | acc]}}

        :dead ->
          {:cont, {:ok, acc}}

        {:error, detail} ->
          {:halt, {:error, "ps failed while listing sessions", detail}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join()}
      error -> error
    end
  end

  defp tmux_alive(pid) do
    case run_cmd("ps", ["-p", Integer.to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
      {out, 0} -> if String.contains?(out, "tmux"), do: :alive, else: :dead
      {_out, 1} -> :dead
      {out, code} -> {:error, "ps exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "could not run ps: #{inspect(e.original)}"}
  end

  # ---- install / uninstall (arb install service) -----------------------------

  @doc """
  Write the wrapper script and the plist: for a dev checkout at `root`, or —
  with `root` `nil` — for a release install under `arbiter_home`. Returns the
  plist path. Both are regenerated on every install.
  """
  @spec write_service_files(root :: Path.t() | nil, arbiter_home :: Path.t(), [
          {String.t(), String.t()}
        ]) ::
          Path.t()
  def write_service_files(root, arbiter_home, env) do
    opts = [root: root, arbiter_home: arbiter_home, env: env]
    wrapper = Plist.wrapper_path(arbiter_home)

    Unit.write_unit(wrapper, Plist.wrapper_script(opts))
    File.chmod!(wrapper, 0o755)
    File.mkdir_p!(Path.dirname(Plist.log_path(arbiter_home)))
    Unit.write_unit(agent_plist_path(), Plist.plist(opts))
    agent_plist_path()
  end

  # launchd has no unit cache to refresh.
  @impl true
  def daemon_reload(_scope), do: :ok

  @impl true
  def enable_now(scope) do
    Start.log_text("Loading and starting #{Plist.label()}…")

    # A job that is already loaded makes `bootstrap` fail with EIO, and would
    # keep running the old plist: unload first so a re-install takes effect.
    _ = launchctl(["bootout", target(scope)])

    # `enable` first: a label that was ever `launchctl disable`d makes
    # `bootstrap` refuse the job.
    _ = launchctl(["enable", target(scope)])

    case launchctl(["bootstrap", domain(scope), plist_path(scope)]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "launchctl bootstrap #{domain(scope)} #{plist_path(scope)} failed (exit #{code})",
          "Inspect it with `#{status_cmd(scope)}` and `#{logs_cmd(scope)}`. Output:\n" <>
            String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      Output.die(
        "could not run launchctl: #{inspect(e.original)}",
        "Is this a macOS host? Ensure `launchctl` is on your PATH."
      )
  end

  # Idempotent unload. Whether the job was actually loaded (a not-loaded job is
  # not fatal).
  @impl true
  def disable_now(scope) do
    match?({_out, 0}, launchctl(["bootout", target(scope)]))
  rescue
    _ -> false
  end

  # A LaunchAgent starts at login, not at boot. Starting before login needs the
  # root-owned LaunchDaemon (`arb install service --system`).
  @impl true
  def enable_boot_start, do: :failed

  @impl true
  def enable_timer(_unit), do: {"log rotation timers are not supported on launchd", 1}

  @impl true
  def disable_timer(_unit), do: {"log rotation timers are not supported on launchd", 1}

  @impl true
  def status_cmd(:system), do: "sudo launchctl print #{shell_target(:system)}"
  def status_cmd(:user), do: "launchctl print #{shell_target(:user)}"

  @impl true
  def logs_cmd(:system), do: "tail -f #{Plist.daemon_log_path()}"
  def logs_cmd(:user), do: "tail -f #{Plist.log_path(Unit.arbiter_home_path())}"

  # ---- operator hints (restart / deploy reports) ----------------------------

  @impl true
  def manager_name, do: "launchd"

  @impl true
  def restart_cmd, do: hint_cmd("launchctl kickstart -k #{shell_target()}")

  @impl true
  def start_cmd, do: hint_cmd("launchctl kickstart #{shell_target()}")

  @impl true
  def stop_cmd, do: hint_cmd("launchctl bootout #{shell_target()}")

  # `bootout` first (it fails harmlessly when nothing is loaded), then load the
  # plist again, which starts the job.
  @impl true
  def recover_cmds do
    [
      stop_cmd(),
      hint_cmd("launchctl bootstrap #{shell_domain()} #{plist_path()}"),
      status_cmd(active_scope())
    ]
  end

  # The system domain is root's: every operator command for it needs `sudo`.
  defp hint_cmd(cmd), do: if(active_scope() == :system, do: "sudo " <> cmd, else: cmd)

  defp shell_domain(scope \\ active_scope())
  defp shell_domain(:system), do: "system"
  defp shell_domain(:user), do: "gui/$(id -u)"

  defp shell_target(scope \\ active_scope()), do: shell_domain(scope) <> "/" <> Plist.label()

  # ---- internals ------------------------------------------------------------

  defp not_loaded?(out, code), do: code in [3, 113] or Regex.match?(@not_loaded, out)

  defp failed(verb, out, code), do: "launchctl #{verb} exited #{code}: #{String.trim(out)}"

  defp domain, do: domain(active_scope())
  defp domain(:user), do: "gui/" <> uid()
  defp domain(:system), do: "system"

  defp target, do: target(active_scope())
  defp target(scope), do: domain(scope) <> "/" <> Plist.label()

  defp root?, do: uid() == "0"

  defp uid do
    case run_cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _code} -> raise ErlangError, original: :uid_unavailable
    end
  end

  defp launchctl(args), do: run_cmd("launchctl", args, stderr_to_stdout: true)

  defp run_cmd(cmd, args, opts), do: Start.run_cmd(cmd, args, opts)
end
