defmodule WardmastCli.Cmd.InstallService.Launchd do
  @moduledoc """
  The macOS half of `arb install service`: install or remove the per-user
  LaunchAgent (`com.wardmast.server`) through `WardmastCli.Supervisor.Launchd`.

  Mirrors the systemd install's two modes, chosen by the same
  `Unit.dev_checkout?/1` test: a source checkout runs its `.run-server.sh`; a
  release install runs `<data-home>/current/bin/wardmast start`, which is what
  `arb server deploy` re-points. Both go through an env-sourcing wrapper. The
  system scope is refused with a message rather than half-installed. Everything the service manager is asked goes through
  `Supervisor.impl()`.
  """

  alias WardmastCli.Cmd.InstallService.{EnvFile, Formatter, Unit}
  alias WardmastCli.Cmd.Start
  alias WardmastCli.Output
  alias WardmastCli.Supervisor
  alias WardmastCli.Supervisor.Launchd

  @spec install(:user | :system, :text | :json) :: :ok
  def install(scope, mode) do
    refuse_system!(scope)
    root = resolve_root()
    dev? = Unit.dev_checkout?(root)

    # Persist the root so `arb start/restart/update` resolve it from any cwd.
    Start.record_home(root)
    arbiter_home = Unit.arbiter_home_path()
    if dev?, do: Unit.ensure_run_server_script(root)

    secrets = EnvFile.capture_secrets(arbiter_home)
    EnvFile.capture_path(arbiter_home)

    path =
      Launchd.write_service_files(if(dev?, do: root), arbiter_home, forwarded_env())

    Supervisor.impl().daemon_reload(scope)
    Supervisor.impl().enable_now(scope)

    Formatter.emit_installed_launchd(mode, path, secrets)
  end

  @spec uninstall(:user | :system, :text | :json) :: :ok
  def uninstall(scope, mode) do
    refuse_system!(scope)
    path = Launchd.plist_path()

    # Idempotent: a job that is not loaded is not an error.
    disabled? = Supervisor.impl().disable_now(scope)
    removed? = Unit.remove_unit(path)
    Supervisor.impl().daemon_reload(scope)

    Formatter.emit_uninstalled_launchd(mode, path, disabled?, removed?)
  end

  defp refuse_system!(:user), do: :ok

  defp refuse_system!(:system) do
    Output.die(
      "--system is not supported on macOS yet",
      "Install the per-user LaunchAgent: run `arb install service` without --system."
    )
  end

  # Same pass-through the systemd dev unit makes (the secrets live in wardmast.env).
  defp forwarded_env do
    for name <- ["WARDMAST_HOST", "WARDMAST_WORKSPACE"],
        value = Wardmast.Env.get(name),
        value not in [nil, ""],
        do: {name, value}
  end

  defp resolve_root do
    case Start.project_root() do
      {:ok, dir} ->
        dir

      :error ->
        Output.die(
          "could not locate the Wardmast project root",
          "Set ARB_HOME to your Wardmast checkout, or run `arb install service` from inside it."
        )
    end
  end
end
