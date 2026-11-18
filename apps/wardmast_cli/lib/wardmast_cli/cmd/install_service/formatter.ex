defmodule WardmastCli.Cmd.InstallService.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb install-service` install/uninstall results.
  """

  alias WardmastCli.Client
  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Output
  alias WardmastCli.SecretInventory
  alias WardmastCli.Supervisor
  alias WardmastCli.Supervisor.Launchd.Plist

  def emit_installed(:json, scope, path, root, linger, secrets, log_paths) do
    {env_path, captured} =
      case secrets do
        {:written, p, keys} -> {p, keys}
        {:none, p} -> {p, []}
      end

    base = %{
      action: "install",
      scope: to_string(scope),
      unit: Unit.unit_name(),
      unit_path: path,
      root: root,
      linger: to_string(linger),
      env_file: env_path,
      secrets_captured: captured,
      secrets_at_rest: at_rest_report(env_path),
      status_cmd: Supervisor.impl().status_cmd(scope),
      logs_cmd: Supervisor.impl().logs_cmd(scope),
      base_url: Client.base_url(),
      ok: true
    }

    base =
      if log_paths do
        {config_path, state_file} = log_paths

        Map.merge(base, %{
          logrotate_timer: Unit.logrotate_timer_name(),
          logrotate_config: config_path,
          logrotate_state: state_file
        })
      else
        base
      end

    Output.emit_json(base)
  end

  def emit_installed(:text, scope, path, arbiter_home, linger, secrets, log_paths) do
    IO.puts("Installed #{Unit.unit_name()} (#{scope} scope).")
    IO.puts("  unit:   #{path}")
    IO.puts("  starts: #{Client.base_url()} at boot")
    IO.puts(secrets_note(secrets))
    IO.puts(at_rest_note(elem(secrets, 1)))
    IO.puts("")
    IO.puts(linger_note(scope, linger))
    IO.puts("Check it with:")
    IO.puts("  #{Supervisor.impl().status_cmd(scope)}")
    IO.puts("  #{Supervisor.impl().logs_cmd(scope)}")

    if log_paths do
      {config_path, state_file} = log_paths
      IO.puts("")
      IO.puts("Logs are written to #{Path.join([arbiter_home, "log", "wardmast.log"])}.")

      IO.puts(
        "A daily systemd timer (#{Unit.logrotate_timer_name()}) rotates logs automatically."
      )

      IO.puts("Rotate manually with:")
      IO.puts("  logrotate --state #{state_file} #{config_path}")
    end

    IO.puts("")

    IO.puts(
      "Remove it with `arb install-service#{if scope == :system, do: " --system", else: ""} --uninstall`."
    )
  end

  def emit_installed_launchd(:json, path, secrets) do
    {env_path, captured} =
      case secrets do
        {:written, p, keys} -> {p, keys}
        {:none, p} -> {p, []}
      end

    Output.emit_json(%{
      action: "install",
      scope: "user",
      unit: Plist.label(),
      unit_path: path,
      env_file: env_path,
      secrets_captured: captured,
      secrets_at_rest: at_rest_report(env_path),
      status_cmd: Supervisor.impl().status_cmd(:user),
      logs_cmd: Supervisor.impl().logs_cmd(:user),
      base_url: Client.base_url(),
      ok: true
    })
  end

  def emit_installed_launchd(:text, path, secrets) do
    IO.puts("Installed #{Plist.label()} (LaunchAgent, user scope).")
    IO.puts("  plist:  #{path}")
    IO.puts("  starts: #{Client.base_url()} at login")
    IO.puts(secrets_note(secrets))
    IO.puts(at_rest_note(elem(secrets, 1)))
    IO.puts("")
    IO.puts("Check it with:")
    IO.puts("  #{Supervisor.impl().status_cmd(:user)}")
    IO.puts("  #{Supervisor.impl().logs_cmd(:user)}")
    IO.puts("")
    IO.puts("Remove it with `arb install service --uninstall`.")
  end

  def emit_installed_launchd_daemon(:json, info, secrets) do
    {env_path, captured} =
      case secrets do
        {:written, p, keys} -> {p, keys}
        {:none, p} -> {p, []}
      end

    Output.emit_json(%{
      action: "install",
      scope: "system",
      unit: Plist.label(),
      unit_path: info.path,
      service_user: info.account.user,
      service_group: info.account.group,
      data_home: info.arbiter_home,
      log_path: info.log_path,
      env_file: env_path,
      secrets_captured: captured,
      secrets_at_rest: at_rest_report(env_path),
      status_cmd: Supervisor.impl().status_cmd(:system),
      logs_cmd: Supervisor.impl().logs_cmd(:system),
      base_url: Client.base_url(),
      ok: true
    })
  end

  def emit_installed_launchd_daemon(:text, info, secrets) do
    IO.puts("Installed #{Plist.label()} (LaunchDaemon, system scope).")
    IO.puts("  plist:   #{info.path}")
    IO.puts("  runs as: #{info.account.user}:#{info.account.group} (never root)")
    IO.puts("  data:    #{info.arbiter_home} (0700, #{info.account.user} only)")
    IO.puts("  logs:    #{info.log_path}")
    IO.puts("  starts:  #{Client.base_url()} at boot, before any login")
    IO.puts(secrets_note(secrets))
    IO.puts(at_rest_note(elem(secrets, 1)))
    IO.puts("")
    IO.puts("Check it with:")
    IO.puts("  #{Supervisor.impl().status_cmd(:system)}")
    IO.puts("  #{Supervisor.impl().logs_cmd(:system)}")
    IO.puts("")
    IO.puts("A release is deployed into the data home above, as the service account:")
    IO.puts("  sudo -H -u #{info.account.user} arb server deploy")
    IO.puts("")
    IO.puts("Remove it with `sudo arb install service --system --uninstall`.")
  end

  def emit_uninstalled_launchd_daemon(:json, path, disabled?, removed?) do
    Output.emit_json(%{
      action: "uninstall",
      scope: "system",
      unit: Plist.label(),
      unit_path: path,
      disabled: disabled?,
      removed: removed?,
      ok: true
    })
  end

  def emit_uninstalled_launchd_daemon(:text, path, disabled?, removed?) do
    IO.puts("Uninstalled #{Plist.label()} (LaunchDaemon, system scope).")
    IO.puts("  unloaded: #{if disabled?, do: "yes", else: "was not loaded"}")
    IO.puts("  removed:  #{if removed?, do: path, else: "no plist at #{path}"}")
    IO.puts("")

    IO.puts(
      "The service account, its data home and #{Plist.daemon_log_dir()} were left in place."
    )
  end

  def emit_uninstalled_launchd(:json, path, disabled?, removed?) do
    Output.emit_json(%{
      action: "uninstall",
      scope: "user",
      unit: Plist.label(),
      unit_path: path,
      disabled: disabled?,
      removed: removed?,
      ok: true
    })
  end

  def emit_uninstalled_launchd(:text, path, disabled?, removed?) do
    IO.puts("Uninstalled #{Plist.label()} (LaunchAgent, user scope).")
    IO.puts("  unloaded: #{if disabled?, do: "yes", else: "was not loaded"}")
    IO.puts("  removed:  #{if removed?, do: path, else: "no plist at #{path}"}")
  end

  def emit_uninstalled(:json, scope, path, disabled?, removed?) do
    Output.emit_json(%{
      action: "uninstall",
      scope: to_string(scope),
      unit: Unit.unit_name(),
      unit_path: path,
      disabled: disabled?,
      removed: removed?,
      ok: true
    })
  end

  def emit_uninstalled(:text, scope, path, disabled?, removed?) do
    IO.puts("Uninstalled #{Unit.unit_name()} (#{scope} scope).")
    IO.puts("  disabled: #{if disabled?, do: "yes", else: "was not enabled"}")
    IO.puts("  removed:  #{if removed?, do: path, else: "no unit file at #{path}"}")

    if scope == :user do
      IO.puts("")
      IO.puts("Linger was left enabled; drop it with `loginctl disable-linger` if no other")
      IO.puts("user services need boot-before-login.")
    end
  end

  defp secrets_note({:written, path, keys}),
    do: "  secrets: #{Enum.join(keys, ", ")} → #{path}"

  defp secrets_note({:none, path}) do
    "  secrets: none found in the environment — set GITHUB_TOKEN (and any\n" <>
      "           ANTHROPIC_API_KEY / GEMINI_API_KEY) then re-run, or add them\n" <>
      "           to #{path} yourself."
  end

  # Which secrets in the env file are inline values and which are `*_REF`
  # pointers to a secret manager. Names and schemes only, never a value.
  defp at_rest_entries(env_path),
    do: env_path |> SecretInventory.env_from_file() |> SecretInventory.classify()

  defp at_rest_report(env_path) do
    entries = at_rest_entries(env_path)

    %{
      inline: for(%{name: n, state: s} <- entries, s in [:inline, :shadowed], do: n),
      references:
        for(
          %{name: n, state: s, scheme: sch} <- entries,
          s in [:ref, :shadowed],
          do: "#{n} (#{sch})"
        ),
      inline_boot_secrets: SecretInventory.inline_boot_secrets(entries)
    }
  end

  defp at_rest_note(env_path) do
    entries = at_rest_entries(env_path)
    base = "  at rest: " <> SecretInventory.summary(entries)

    case SecretInventory.inline_boot_secrets(entries) do
      [] ->
        base

      inline ->
        base <>
          "\n           " <>
          Enum.join(inline, ", ") <>
          " sit inline in the env file; set <NAME>_REF=aws-sm:<id>#<key> (or aws-ssm:/file:)\n" <>
          "           and remove the value to keep it off this disk. See docs/secrets-at-rest.md."
    end
  end

  defp linger_note(:system, _), do: "Enabled at boot via the system manager."

  defp linger_note(:user, :enabled),
    do: "Enabled boot-before-login via `loginctl enable-linger`."

  defp linger_note(:user, :failed) do
    "warning: could not enable linger automatically. The service will start at your\n" <>
      "next login. For boot-before-login, run: loginctl enable-linger #{System.get_env("USER")}"
  end
end
