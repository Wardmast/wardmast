defmodule WardmastCli.Cmd.InstallService do
  @moduledoc """
  `arb install-service [--system] [--uninstall] [--json]` — install a systemd
  unit so the Wardmast stack comes up automatically at machine boot.

  On macOS the same command installs a per-user launchd LaunchAgent instead
  (`Cmd.InstallService.Launchd`), or with `--system` a system-wide LaunchDaemon
  for a shared team Mac: `sudo ward install service --system [--service-user
  NAME]` (default `_wardmast`; the account must already exist, release mode
  only, runs as that account at boot). Everything below about systemd and
  `systemctl` describes the Linux path.

  Two modes, chosen automatically from the resolved project root (the same
  root `arb start` resolves via `ARB_HOME` / the recorded home / a directory
  walk):

    * **Release install (default)** — when the root is not a source checkout,
      `ExecStart` is `~/.wardmast/current/bin/wardmast start`, the
      self-contained OTP release.
    * **Dev-mode source checkout** — when the root looks like an Wardmast
      source checkout (`mix.exs` + `apps/`, the same heuristic
      `Cmd.Start.umbrella_root?/1` uses), `ExecStart` instead runs
      `<root>/.run-server.sh`, a small `exec`-chain launcher that `cd`s to
      the checkout, sources the checkout's own `.wardmast.env` (for
      `SECRET_KEY_BASE`, `DATABASE_PATH`, and similar dev-only settings that
      `EnvironmentFile=` below doesn't carry), and `exec`s `mix phx.server`
      directly — so systemd tracks the real BEAM process instead of a
      detached background job. The script is generated at
      `<root>/.run-server.sh` if it doesn't already exist; an existing
      script is never overwritten. Note this script is also what
      `Cmd.Start.start_phoenix/1` prefers for plain `arb start`/`arb restart`
      when present, so it has to work standalone, not just under systemd.

  Either way the service runs as a long-lived foreground process
  (`Type=exec`), tracked by systemd for the full lifetime of the VM. Which
  mode a given box gets is stable across re-runs — it only depends on
  whether the resolved root is a source checkout, not on incidental state —
  so re-running `arb install-service` never flips a working install from one
  mode to the other.

  ## Scope

    * **User (default)** — written to `~/.config/systemd/user/wardmast.service`
      and managed with `systemctl --user`. Installs run without root. Because a
      user manager normally exits at logout, the command also runs
      `loginctl enable-linger` so the service starts at *boot*, before any
      login.
    * **System (`--system`)** — written to `/etc/systemd/system/wardmast.service`
      and managed with plain `systemctl`. Writing there and reloading the
      system manager need root, so run with `sudo` if you aren't already.

  ## What it writes

  The unit references `EnvironmentFile=~/.wardmast/wardmast.env` (created and
  managed by this command) for secrets and optional overrides — in both
  modes, so a dev-mode checkout's `mix`/`elixir` (found via the captured
  `PATH`) resolve the same way whether started by hand or by systemd. In
  release mode `PATH`/`MIX_HOME` aren't needed (the release is
  self-contained); in dev mode they're picked up from that same captured
  `PATH`. `ARB_HOST` and `ARB_WORKSPACE`, when set in the installing shell,
  are forwarded as `Environment=` lines in both modes; dev mode additionally
  forwards `ARB_HOME=<root>`.

  ## Secret capture

  A boot-time service starts with no interactive shell, so the API keys you
  normally export (`GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, …) are
  not visible to it. To bridge that gap, install captures any of those keys that
  are set in the *installing* shell and writes them to `~/.wardmast/wardmast.env`
  (the same file `EnvironmentFile=` points at). Existing entries are preserved —
  a managed key already present is updated in place, sibling keys and comments
  are left untouched — and the file is locked to `0600` since it holds secrets.

  ## Idempotent

  Re-running rewrites the unit and reloads the daemon, so it's safe to run
  twice — handy after upgrading the release.

  ## Teardown

  `--uninstall` reverses everything: `disable --now` the unit, remove the file,
  and reload the daemon. Linger is left alone (other user services may rely on
  it); the printed notes mention how to drop it.

  ## Exit codes

    * `0` — installed (or uninstalled) successfully.
    * `1` — a prerequisite was missing (project root, `systemctl`), or a
      `systemctl`/`loginctl` step failed.
  """

  alias WardmastCli.ArgParser
  alias WardmastCli.Cmd.InstallService.{EnvFile, Formatter, Unit}
  alias WardmastCli.Cmd.InstallService.Launchd, as: LaunchdInstall
  alias WardmastCli.Cmd.{Restart, Start}
  alias WardmastCli.Output
  alias WardmastCli.Supervisor

  @switches [
    system: :boolean,
    uninstall: :boolean,
    json: :boolean,
    force: :boolean,
    service_user: :string
  ]

  @logrotate_service_name "wardmast-logrotate.service"

  def run(argv) do
    ArgParser.unless_help(argv, @moduledoc, fn ->
      {opts, _rest, mode} =
        ArgParser.parse(argv, command: "ward install service", switches: @switches)

      scope = if opts[:system], do: :system, else: :user
      force = opts[:force] || false

      launchd? = Supervisor.impl() == Supervisor.Launchd

      cond do
        opts[:uninstall] && launchd? ->
          LaunchdInstall.uninstall(scope, mode)

        opts[:uninstall] ->
          uninstall(scope, mode)

        true ->
          Restart.guard_worker_session!()
          Restart.guard_active_workers!(force)
          
          if launchd?,
            do: LaunchdInstall.install(scope, mode, service_user: opts[:service_user]),
            else: install(scope, mode)

      end
    end)
  end

  # ---- install -----------------------------------------------------------

  defp install(scope, mode) do
    root = resolve_root()
    # Persist the root so `arb start/restart/update` resolve it from any cwd.
    Start.record_home(root)
    arbiter_home = Unit.arbiter_home_path()
    path = unit_path(scope)
    if Unit.dev_checkout?(root), do: Unit.ensure_run_server_script(root)
    contents = Unit.unit_contents(scope, arbiter_home, root)

    secrets = EnvFile.capture_secrets(arbiter_home)
    EnvFile.capture_path(arbiter_home)

    log_paths = if scope == :user, do: setup_log_dir(arbiter_home), else: nil

    Unit.write_unit(path, contents)
    Supervisor.impl().daemon_reload(scope)
    Supervisor.impl().enable_now(scope)
    if scope == :user, do: enable_logrotate_timer()
    linger = if scope == :user, do: Supervisor.impl().enable_boot_start(), else: :not_applicable

    Formatter.emit_installed(mode, scope, path, arbiter_home, linger, secrets, log_paths)
  end

  # Create ~/.wardmast/log/, write a logrotate config, and install a user-scoped
  # systemd service + daily timer so rotation runs automatically without cron or
  # manual intervention. Uses copytruncate so the running service's open file
  # descriptor keeps working without a restart.
  defp setup_log_dir(arbiter_home) do
    log_dir = Path.join(arbiter_home, "log")
    File.mkdir_p!(log_dir)

    log_file = Path.join(log_dir, "wardmast.log")
    state_file = Path.join(log_dir, "logrotate.state")
    config_path = Path.join(log_dir, "logrotate.conf")

    config = """
    "#{log_file}" {
        daily
        rotate 7
        compress
        missingok
        notifempty
        copytruncate
    }
    """

    File.write!(config_path, config)

    # Write logrotate service + timer units so daemon-reload picks them up in
    # the same cycle as the main wardmast.service unit.
    svc_path = Path.join(unit_dir(:user), @logrotate_service_name)
    timer_path = Path.join(unit_dir(:user), Unit.logrotate_timer_name())
    Unit.write_unit(svc_path, logrotate_service_contents(config_path, state_file))
    Unit.write_unit(timer_path, logrotate_timer_contents())

    {config_path, state_file}
  end

  defp logrotate_service_contents(config_path, state_file) do
    """
    [Unit]
    Description=Rotate Wardmast log file

    [Service]
    Type=oneshot
    ExecStart=logrotate --state #{state_file} #{config_path}
    """
  end

  defp logrotate_timer_contents do
    """
    [Unit]
    Description=Daily rotation of Wardmast log file

    [Timer]
    OnCalendar=daily
    Persistent=true

    [Install]
    WantedBy=timers.target
    """
  end

  # Enable the daily logrotate timer for user installs. Non-fatal if logrotate
  # is missing — the log file still works, just won't auto-rotate.
  defp enable_logrotate_timer do
    case Supervisor.impl().enable_timer(Unit.logrotate_timer_name()) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Start.log_text(
          "warning: could not enable #{Unit.logrotate_timer_name()} (exit #{code}): #{String.trim(out)}"
        )
    end
  end

  # ---- uninstall ---------------------------------------------------------

  defp uninstall(scope, mode) do
    path = unit_path(scope)

    # `disable --now` both stops and de-links the unit. Tolerate a non-zero
    # exit (already disabled / never installed) so uninstall is idempotent.
    disabled? = Supervisor.impl().disable_now(scope)

    if scope == :user do
      Supervisor.impl().disable_timer(Unit.logrotate_timer_name())
      Unit.remove_unit(Path.join(unit_dir(:user), Unit.logrotate_timer_name()))
      Unit.remove_unit(Path.join(unit_dir(:user), @logrotate_service_name))
    end

    removed? = Unit.remove_unit(path)
    Supervisor.impl().daemon_reload(scope)

    Formatter.emit_uninstalled(mode, scope, path, disabled?, removed?)
  end

  # ---- unit content (public for tests) ------------------------------------

  @spec unit_contents(:user | :system, String.t(), String.t()) :: String.t()
  defdelegate unit_contents(scope, arbiter_home, root), to: Unit

  @spec capture_secrets(String.t()) ::
          {:written, String.t(), [String.t()]} | {:none, String.t()}
  defdelegate capture_secrets(arbiter_home), to: EnvFile

  @doc """
  Capture the installing shell's PATH into `<arbiter_home>/wardmast.env`.
  Called from `arb install service` and from `arb server deploy`.
  """
  @spec capture_path(String.t()) :: :written | :skipped
  defdelegate capture_path(arbiter_home), to: EnvFile

  # ---- resolution --------------------------------------------------------

  defp resolve_root do
    case Start.project_root() do
      {:ok, dir} ->
        dir

      :error ->
        Output.die(
          "could not locate the Wardmast project root (no compose.yml found)",
          "Set ARB_HOME to your Wardmast checkout, or run `arb install-service` from inside it."
        )
    end
  end

  @doc """
  Directory the unit is written to for `scope`. Tests override via the
  `:bd2_unit_dir` process-dict seam so they can write to a tmp dir without
  touching the real systemd locations.
  """
  @spec unit_dir(:user | :system) :: String.t()
  def unit_dir(scope) do
    case Process.get(:bd2_unit_dir) do
      dir when is_binary(dir) -> dir
      _ -> default_unit_dir(scope)
    end
  end

  defp default_unit_dir(:user), do: Path.join([System.user_home!(), ".config", "systemd", "user"])
  defp default_unit_dir(:system), do: "/etc/systemd/system"

  defp unit_path(scope), do: Path.join(unit_dir(scope), Unit.unit_name())
end
