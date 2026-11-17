defmodule WardmastCli.Supervisor.Systemd do
  @moduledoc """
  `WardmastCli.Supervisor` backend for Linux/systemd: the only module in the
  CLI that spawns `systemctl`, `loginctl` or names `journalctl`.

  Command shapes and failure wording are exactly what `arb restart`,
  `arb session list` and `arb install-service` used before the extraction.
  """

  @behaviour WardmastCli.Supervisor

  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Cmd.Start
  alias WardmastCli.Output

  @unit "wardmast.service"

  # ---- service probe / lifecycle (arb restart) -------------------------------

  @impl true
  def service_state do
    case run_cmd("systemctl", ["--user", "cat", @unit], stderr_to_stdout: true) do
      {_out, 0} ->
        :managed

      {out, code} ->
        if Regex.match?(~r/No files found|could not be found|not-found/i, out) do
          :not_found
        else
          {:unreachable, "systemctl exited #{code}: #{String.trim(out)}"}
        end
    end
  rescue
    e in ErlangError ->
      # systemctl is not installed (macOS, minimal container): there is no
      # systemd to be in charge. Anything else is "could not ask".
      if e.original == :enoent,
        do: :not_found,
        else: {:unreachable, "could not run systemctl: #{inspect(e.original)}"}
  end

  # Where `arb install-service` (and packages) put the unit. The
  # `:bd2_unit_dirs` seam lets tests point at a scratch dir.
  @impl true
  def unit_dirs do
    case Process.get(:bd2_unit_dirs) do
      dirs when is_list(dirs) ->
        dirs

      _ ->
        config_home =
          System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")

        [
          Path.join(config_home, "systemd/user"),
          "/etc/systemd/user",
          "/etc/systemd/system",
          "/usr/lib/systemd/user",
          "/usr/lib/systemd/system"
        ]
    end
  end

  @impl true
  def stop_service do
    case run_cmd("systemctl", ["--user", "stop", @unit], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "systemctl stop exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "could not run systemctl: #{inspect(e.original)}"}
  end

  # `--no-block`: a plain `restart` waits for the start job and hangs for as
  # long as systemd leaves that job in `waiting` (the 2026-10-11 outage). The
  # caller enqueues the job and watches the unit itself, bounded.
  @impl true
  def restart_service do
    case run_cmd("systemctl", ["--user", "restart", "--no-block", @unit], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error, "systemctl --user restart #{@unit} failed (exit #{code})",
         "Output:\n" <> String.trim_trailing(out)}
    end
  rescue
    e in ErlangError ->
      {:error, "could not run systemctl: #{inspect(e.original)}",
       "Ensure systemctl is on your PATH."}
  end

  # ActiveState/InvocationID/Job of the unit, or nil when unreadable.
  @impl true
  def service_info do
    args = [
      "--user",
      "show",
      @unit,
      "-p",
      "ActiveState",
      "-p",
      "InvocationID",
      "-p",
      "Job"
    ]

    case run_cmd("systemctl", args, stderr_to_stdout: true) do
      {out, 0} -> parse_unit_info(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_unit_info(out) do
    props =
      for line <- String.split(out, "\n", trim: true),
          [k, v] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {k, String.trim(v)}

    case props do
      %{"ActiveState" => state} when state != "" ->
        %{state: state, invocation_id: props["InvocationID"] || "", job: props["Job"]}

      _ ->
        nil
    end
  end

  @impl true
  def recover_stuck_service do
    _ = run_cmd("systemctl", ["--user", "daemon-reexec"], stderr_to_stdout: true)

    _ =
      run_cmd("systemctl", ["--user", "start", "--no-block", @unit], stderr_to_stdout: true)

    :ok
  rescue
    e in ErlangError ->
      Start.log_text("recovery failed: #{inspect(e.original)}")
      :ok
  end

  # ---- session scopes (arb session list) -------------------------------------

  @impl true
  def list_scopes(prefix) do
    case run_cmd(
           "systemctl",
           ["--user", "list-units", prefix <> "*", "--no-legend", "--plain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, "systemctl exited #{status}: #{String.trim(output)}",
         "Is a systemd --user manager running for this user? " <>
           "(over ssh, `loginctl enable-linger $USER` may be needed.)"}
    end
  rescue
    e in ErlangError ->
      {:error, "could not run systemctl: #{Exception.message(e)}",
       "Is systemd installed and on PATH?"}
  end

  # ---- install / uninstall (arb install-service) -----------------------------

  @impl true
  def daemon_reload(scope) do
    case systemctl(scope, ["daemon-reload"]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "systemctl daemon-reload failed (exit #{code})",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  @impl true
  def enable_now(scope) do
    Start.log_text("Enabling and starting #{Unit.unit_name()}…")

    case systemctl(scope, ["enable", "--now", Unit.unit_name()]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "systemctl enable --now #{Unit.unit_name()} failed (exit #{code})",
          "Inspect it with `#{status_cmd(scope)}` and `#{logs_cmd(scope)}`. Output:\n" <>
            String.trim_trailing(out)
        )
    end
  end

  # Idempotent stop+disable. Returns whether the unit was actually disabled (a
  # non-zero exit means it wasn't installed / already disabled — not fatal).
  @impl true
  def disable_now(scope) do
    case systemctl(scope, ["disable", "--now", Unit.unit_name()]) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  # Boot-before-login for user services. Idempotent; non-zero is non-fatal
  # (e.g. a non-systemd-logind host) so the install still succeeds — we just
  # report that linger couldn't be enabled.
  @impl true
  def enable_boot_start do
    user = System.get_env("USER") || System.get_env("LOGNAME") || ""

    case run_cmd("loginctl", ["enable-linger" | linger_args(user)], stderr_to_stdout: true) do
      {_out, 0} -> :enabled
      {_out, _nonzero} -> :failed
    end
  rescue
    e in ErlangError ->
      # loginctl missing — surface as "couldn't enable" rather than aborting.
      _ = e
      :failed
  end

  defp linger_args(""), do: []
  defp linger_args(user), do: [user]

  @impl true
  def enable_timer(unit), do: systemctl(:user, ["enable", "--now", unit])

  @impl true
  def disable_timer(unit), do: systemctl(:user, ["disable", "--now", unit])

  # Scope-aware inspection commands echoed in the success/error output.
  @impl true
  def status_cmd(:user), do: "systemctl --user status #{Unit.unit_name()}"
  def status_cmd(:system), do: "systemctl status #{Unit.unit_name()}"

  # User services write to a file (no journald permissions needed); system
  # installs have root so journalctl works directly.
  @impl true
  def logs_cmd(:user) do
    log_file = Path.join([Unit.arbiter_home_path(), "log", "wardmast.log"])
    "tail -f #{log_file}"
  end

  def logs_cmd(:system), do: "journalctl -u #{Unit.unit_name()} -f"

  # ---- internals ------------------------------------------------------------

  defp systemctl(scope, args) do
    full = if scope == :user, do: ["--user" | args], else: args

    run_cmd("systemctl", full, stderr_to_stdout: true)
  rescue
    e in ErlangError ->
      Output.die(
        "could not run systemctl: #{inspect(e.original)}",
        "Is this a systemd host? Ensure `systemctl` is on your PATH."
      )
  end

  defp run_cmd(cmd, args, opts), do: Start.run_cmd(cmd, args, opts)
end
