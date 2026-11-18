defmodule WardmastCli.Cmd.InstallService.Launchd do
  @moduledoc """
  The macOS half of `arb install service`: install or remove the launchd job
  (`com.wardmast.server`) through `WardmastCli.Supervisor.Launchd`, in one of
  two shapes.

  ## LaunchAgent (default, single developer)

  A per-user agent in `~/Library/LaunchAgents`, loaded into `gui/<uid>`. Mirrors
  the systemd install's two modes, chosen by the same `Unit.dev_checkout?/1`
  test: a source checkout runs its `.run-server.sh`; a release install runs
  `<data-home>/current/bin/wardmast start`, which is what `arb server deploy`
  re-points. Both go through an env-sourcing wrapper.

  ## LaunchDaemon (`--system`, team / shared Mac host)

  A system-wide job in `/Library/LaunchDaemons`, loaded into the `system`
  domain, started at boot. Needs root (`sudo arb install service --system`) and
  a **dedicated service account** (`--service-user`, default `_wardmast`) that
  must already exist; this command does not create accounts. The daemon:

    * runs as that account (`UserName` / `GroupName`), never as root — a
      service user that is `root` or resolves to uid 0 is refused;
    * is release mode only (no checkout: it must not run out of one person's
      home), with its data home at `<service user's home>/.wardmast`, mode
      `0700` and owned by the service account, so other users of the host
      cannot read its database or `wardmast.env`;
    * has a root-owned, mode `0644` plist (launchd refuses a daemon plist
      that is writable by anyone else) and logs to `/Library/Logs/Wardmast`
      (`0750`, service-account owned);
    * excludes the LaunchAgent: with either installed, installing the other is
      refused, because both would run a server on the same port.

  Everything the service manager is asked goes through `Supervisor.impl()`.
  """

  alias WardmastCli.Cmd.InstallService.{EnvFile, Formatter, Unit}
  alias WardmastCli.Cmd.Start
  alias WardmastCli.Output
  alias WardmastCli.Supervisor
  alias WardmastCli.Supervisor.Launchd
  alias WardmastCli.Supervisor.Launchd.Plist

  @default_service_user "_wardmast"

  @doc "Default dedicated service account for the LaunchDaemon."
  @spec default_service_user() :: String.t()
  def default_service_user, do: @default_service_user

  @spec install(:user | :system, :text | :json, keyword()) :: :ok
  def install(scope, mode, opts \\ [])

  def install(:user, mode, _opts) do
    refuse_if_daemon_installed!("install the per-user LaunchAgent")
    root = resolve_root()
    dev? = Unit.dev_checkout?(root)

    arbiter_home = if dev?, do: Unit.arbiter_home_path(), else: release_home(root)
    unless dev?, do: require_release_bin!(arbiter_home)

    # Persist the root so `arb start/restart/update` resolve it from any cwd.
    Start.record_home(root)
    if dev?, do: Unit.ensure_run_server_script(root)

    secrets = EnvFile.capture_secrets(arbiter_home)
    EnvFile.capture_path(arbiter_home)

    path =
      Launchd.write_service_files(if(dev?, do: root), arbiter_home, forwarded_env())

    Supervisor.impl().daemon_reload(:user)
    Supervisor.impl().enable_now(:user)

    Formatter.emit_installed_launchd(mode, path, secrets)
  end

  def install(:system, mode, opts) do
    require_root!("install the LaunchDaemon")
    refuse_if_agent_installed!()

    account = resolve_account!(Keyword.get(opts, :service_user) || @default_service_user)
    arbiter_home = Path.join(account.home, ".wardmast")

    prepare_data_home!(arbiter_home, account)
    secrets = EnvFile.capture_secrets(arbiter_home)
    EnvFile.capture_path(arbiter_home)

    path = write_daemon_files(arbiter_home, account)
    chown(["-R", owner(account), arbiter_home])

    Supervisor.impl().daemon_reload(:system)
    Supervisor.impl().enable_now(:system)

    Formatter.emit_installed_launchd_daemon(
      mode,
      %{
        path: path,
        account: account,
        arbiter_home: arbiter_home,
        log_path: Plist.daemon_log_path()
      },
      secrets
    )
  end

  @spec uninstall(:user | :system, :text | :json) :: :ok
  def uninstall(:user, mode) do
    if File.exists?(Launchd.daemon_plist_path()) and not File.exists?(Launchd.agent_plist_path()) do
      Output.die(
        "no per-user LaunchAgent is installed, but a system-wide LaunchDaemon is",
        "Remove it with `sudo arb install service --system --uninstall`."
      )
    end

    path = Launchd.agent_plist_path()

    # Idempotent: a job that is not loaded is not an error.
    disabled? = Supervisor.impl().disable_now(:user)
    removed? = Unit.remove_unit(path)
    Supervisor.impl().daemon_reload(:user)

    Formatter.emit_uninstalled_launchd(mode, path, disabled?, removed?)
  end

  def uninstall(:system, mode) do
    require_root!("remove the LaunchDaemon")
    path = Launchd.daemon_plist_path()

    disabled? = Supervisor.impl().disable_now(:system)
    removed? = Unit.remove_unit(path)
    Supervisor.impl().daemon_reload(:system)

    Formatter.emit_uninstalled_launchd_daemon(mode, path, disabled?, removed?)
  end

  # The data home a release install runs from. The test seam wins; otherwise an
  # explicit `ARB_HOME` is honoured (`<ARB_HOME>/.wardmast`, or `ARB_HOME`
  # itself when that is where `current` lives); else the default `~/.wardmast`.
  defp release_home(root) do
    nested = Path.join(root, ".wardmast")

    cond do
      Process.get(:bd2_arbiter_home) -> Unit.arbiter_home_path()
      System.get_env("ARB_HOME") in [nil, ""] -> Unit.arbiter_home_path()
      File.exists?(Plist.release_bin(nested)) -> nested
      File.exists?(Plist.release_bin(root)) -> root
      true -> nested
    end
  end

  defp require_release_bin!(arbiter_home) do
    bin = Plist.release_bin(arbiter_home)

    unless File.exists?(bin) do
      Output.die(
        "release binary not found: #{bin}",
        "Install a release into #{arbiter_home} first (`arb server deploy`), or set ARB_HOME " <>
          "to the home that holds `current/`, then re-run `arb install service`."
      )
    end

    :ok
  end

  # ---- daemon pieces ---------------------------------------------------------

  defp require_root!(what) do
    case Start.run_cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} ->
        if String.trim(out) == "0", do: :ok, else: not_root!(what)

      _ ->
        not_root!(what)
    end
  end

  @spec not_root!(String.t()) :: no_return()
  defp not_root!(what) do
    Output.die(
      "cannot #{what}: --system needs root",
      "Re-run with sudo: `sudo arb install service --system`" <>
        " (the daemon itself will run as the service account, not root)."
    )
  end

  defp refuse_if_agent_installed! do
    if File.exists?(Launchd.agent_plist_path()) do
      Output.die(
        "a per-user LaunchAgent is installed (#{Launchd.agent_plist_path()}); " <>
          "a LaunchDaemon next to it would run a second server on the same port",
        "Remove the LaunchAgent first, as the user that installed it: " <>
          "`arb install service --uninstall`."
      )
    end
  end

  defp refuse_if_daemon_installed!(what) do
    if File.exists?(Launchd.daemon_plist_path()) do
      Output.die(
        "a system-wide LaunchDaemon is installed (#{Launchd.daemon_plist_path()}); " <>
          "cannot #{what} next to it (two servers, one port)",
        "Remove the LaunchDaemon first: `sudo arb install service --system --uninstall`."
      )
    end
  end

  # Resolve the service account through the directory service, never by guessing
  # a path: its home is where the data home lives, its uid must not be 0.
  defp resolve_account!("root") do
    Output.die(
      "refusing to run the Wardmast server as root",
      "Pass a dedicated, unprivileged account with --service-user (default #{@default_service_user})."
    )
  end

  defp resolve_account!(user) do
    home = account_home!(user)
    uid = account_uid!(user)

    if uid == 0 do
      Output.die(
        "account #{user} has uid 0: refusing to run the Wardmast server as root",
        "Pass a dedicated, unprivileged account with --service-user."
      )
    end

    %{user: user, uid: uid, group: account_group(user), home: home}
  end

  defp account_home!(user) do
    case Start.run_cmd("dscl", [".", "-read", "/Users/#{user}", "NFSHomeDirectory"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Regex.run(~r/NFSHomeDirectory:\s*(\S.*)$/m, out) do
          [_, home] -> String.trim(home)
          _ -> missing_account!(user)
        end

      _ ->
        missing_account!(user)
    end
  end

  @spec missing_account!(String.t()) :: no_return()
  defp missing_account!(user) do
    Output.die(
      "service account #{user} does not exist (or has no home directory)",
      "Create it first, e.g. `sudo sysadminctl -addUser #{user} -home /Users/#{user} -shell /usr/bin/false` " <>
        "and make sure /Users/#{user} exists; see #{WardmastCli.Version.doc_url("docs/running-on-macos.md")} (team Mac). " <>
        "Or pass an existing unprivileged account with --service-user."
    )
  end

  defp account_uid!(user) do
    with {out, 0} <- Start.run_cmd("id", ["-u", user], stderr_to_stdout: true),
         {uid, ""} <- out |> String.trim() |> Integer.parse() do
      uid
    else
      _ -> missing_account!(user)
    end
  end

  defp account_group(user) do
    case Start.run_cmd("id", ["-gn", user], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "staff"
    end
  end

  defp owner(account), do: account.user <> ":" <> account.group

  # 0700: other users of a shared host must not read the database, the
  # captured secrets (`wardmast.env`) or the operator socket under it.
  defp prepare_data_home!(arbiter_home, account) do
    File.mkdir_p!(arbiter_home)
    File.chmod!(arbiter_home, 0o700)
    chown([owner(account), arbiter_home])
  end

  defp write_daemon_files(arbiter_home, account) do
    opts = [
      mode: :daemon,
      user_name: account.user,
      group_name: account.group,
      user_home: account.home,
      arbiter_home: arbiter_home,
      env: forwarded_env()
    ]

    wrapper = Plist.wrapper_path(arbiter_home)
    Unit.write_unit(wrapper, Plist.wrapper_script(opts))
    File.chmod!(wrapper, 0o755)

    log_dir = Launchd.daemon_log_dir()
    File.mkdir_p!(log_dir)
    File.chmod!(log_dir, 0o750)
    chown([owner(account), log_dir])

    path = Launchd.daemon_plist_path()
    Unit.write_unit(path, Plist.plist(opts))
    # launchd ignores a daemon plist that is not root-owned or is writable by
    # anyone else.
    File.chmod!(path, 0o644)
    chown(["root:wheel", path])
    path
  end

  defp chown(args) do
    case Start.run_cmd("chown", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "chown #{Enum.join(args, " ")} failed (exit #{code})",
          String.trim_trailing(out)
        )
    end
  end

  # ---- shared --------------------------------------------------------------

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
