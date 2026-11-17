defmodule WardmastCli.Supervisor.Launchd do
  @moduledoc """
  `WardmastCli.Supervisor` backend for macOS/launchd: with `Supervisor.Systemd`
  one of only two modules in the CLI that spawn a service-manager executable
  (here `launchctl`).

  Phase 1 manages one per-user LaunchAgent (`com.wardmast.server`, in the
  `gui/<uid>` domain) that runs a dev checkout via an env-sourcing wrapper
  (see `Launchd.Plist`). It sits under the same restart/health state machine
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

  Not available in phase 1, reported rather than faked: boot-before-login
  start (a LaunchAgent starts at login), logrotate timers, `arb-session-*`
  scopes (a systemd concept), and the system (`--system`) scope.
  """

  @behaviour WardmastCli.Supervisor

  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Cmd.Start
  alias WardmastCli.Output
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

  @doc "Full path of the service's plist."
  @spec plist_path() :: Path.t()
  def plist_path, do: Path.join(plist_dir(), Plist.file_name())

  @impl true
  def unit_dirs, do: [plist_dir()]

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
    case launchctl(["kickstart", "-k", target()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        if not_loaded?(out, code), do: bootstrap_unloaded(), else: kickstart_failed(out, code)
    end
  rescue
    e in ErlangError ->
      {:error, "could not run launchctl: #{inspect(e.original)}",
       "Ensure launchctl is on your PATH."}
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

  # `arb-session-*` are transient systemd scopes; launchd has none, so the
  # listing is empty rather than an error.
  @impl true
  def list_scopes(_prefix), do: {:ok, ""}

  # ---- install / uninstall (arb install service) -----------------------------

  @doc """
  Write the wrapper script and the plist for a dev checkout at `root`.
  Returns the plist path. Both are regenerated on every install.
  """
  @spec write_service_files(root :: Path.t(), arbiter_home :: Path.t(), [{String.t(), String.t()}]) ::
          Path.t()
  def write_service_files(root, arbiter_home, env) do
    opts = [root: root, arbiter_home: arbiter_home, env: env]
    wrapper = Plist.wrapper_path(arbiter_home)

    Unit.write_unit(wrapper, Plist.wrapper_script(opts))
    File.chmod!(wrapper, 0o755)
    File.mkdir_p!(Path.dirname(Plist.log_path(arbiter_home)))
    Unit.write_unit(plist_path(), Plist.plist(opts))
    plist_path()
  end

  # launchd has no unit cache to refresh.
  @impl true
  def daemon_reload(_scope), do: :ok

  @impl true
  def enable_now(scope) do
    require_user_scope!(scope)
    Start.log_text("Loading and starting #{Plist.label()}…")

    # A job that is already loaded makes `bootstrap` fail with EIO, and would
    # keep running the old plist: unload first so a re-install takes effect.
    _ = launchctl(["bootout", target()])

    # `enable` first: a label that was ever `launchctl disable`d makes
    # `bootstrap` refuse the job.
    _ = launchctl(["enable", target()])

    case launchctl(["bootstrap", domain(), plist_path()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "launchctl bootstrap #{domain()} #{plist_path()} failed (exit #{code})",
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
  def disable_now(_scope) do
    match?({_out, 0}, launchctl(["bootout", target()]))
  rescue
    _ -> false
  end

  # A LaunchAgent starts at login, not at boot. Starting before login needs a
  # root-owned LaunchDaemon, which phase 1 does not install.
  @impl true
  def enable_boot_start, do: :failed

  @impl true
  def enable_timer(_unit), do: {"log rotation timers are not supported on launchd", 1}

  @impl true
  def disable_timer(_unit), do: {"log rotation timers are not supported on launchd", 1}

  @impl true
  def status_cmd(_scope), do: "launchctl print gui/$(id -u)/#{Plist.label()}"

  @impl true
  def logs_cmd(_scope), do: "tail -f #{Plist.log_path(Unit.arbiter_home_path())}"

  # ---- internals ------------------------------------------------------------

  defp require_user_scope!(:user), do: :ok

  defp require_user_scope!(:system) do
    Output.die(
      "--system is not supported on macOS yet",
      "Install the per-user LaunchAgent: run `arb install service` without --system."
    )
  end

  defp not_loaded?(out, code), do: code in [3, 113] or Regex.match?(@not_loaded, out)

  defp failed(verb, out, code), do: "launchctl #{verb} exited #{code}: #{String.trim(out)}"

  defp domain, do: "gui/" <> uid()
  defp target, do: domain() <> "/" <> Plist.label()

  defp uid do
    case run_cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _code} -> raise ErlangError, original: :uid_unavailable
    end
  end

  defp launchctl(args), do: run_cmd("launchctl", args, stderr_to_stdout: true)

  defp run_cmd(cmd, args, opts), do: Start.run_cmd(cmd, args, opts)
end
