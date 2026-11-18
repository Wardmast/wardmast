defmodule Wardmast.Release.SelfDeploy do
  @moduledoc """
  Launch `arb server deploy` for an operator who asked for an update — the
  dashboard's "Update to vX.Y.Z" button and `POST /api/release/deploy`.

  ## Why a separate systemd unit

  The deploy restarts `wardmast.service`, i.e. kills this BEAM mid-deploy. So it
  cannot run as a child of the server, nor even in its cgroup. It is started with

      systemd-run --user --unit=wardmast-deploy-<tag> --collect … arb server deploy --version <tag> --json

  which makes a transient service of the *user manager*, outside
  `wardmast.service`, that survives the restart and runs the same deploy an
  operator would run by hand (backup, swap, health check, rollback, CLI update).
  Its progress and outcome are the CLI's own status file
  (`Wardmast.Release.DeployStatus`), which the dashboard reads once the server is
  back.

  ## Guards

    * Only a plain `vX.Y.Z` tag is deployable: the tag is an argv element of a
      process run as the operator, so it is validated rather than escaped, and a
      branch, ref or option can never reach it.
    * One deploy at a time: refused while any `wardmast-deploy-*` unit is active
      or the status file says a live deploy is running. A record whose process
      died does not block.
    * Secrets never travel in argv or logs. The unit gets the service's
      environment through `EnvironmentFile=-<data-home>/wardmast.env` (where
      `GITHUB_TOKEN` already lives), and anything printed back is scrubbed of
      the token's value.

  ## On macOS: a detached launchd job

  There is no systemd on darwin, so the runner is a one-shot launchd job instead:
  `<data-home>/wardmast-deploy-<tag>.plist` (label `wardmast-deploy-<tag>`, no
  `KeepAlive`, `RunAtLoad`) is `launchctl bootstrap`ped into the user's `gui/<uid>`
  domain. launchd, not this BEAM, owns the process, so the restart it triggers
  cannot take it down. launchd has no `EnvironmentFile=`, so the job's `/bin/sh -c`
  wrapper sources `<data-home>/wardmast.env` itself (the plist never carries the
  token) and `exec`s the CLI; the tag is a positional argument of that script,
  never interpolated into it. "A deploy is running" is a job in `launchctl list`
  with a live PID — a finished job lingers listed with `-` and does not block.

  Authorisation is the caller's job and is operator-only: the REST route is
  `:operator` in `WardmastWeb.ApiPolicy`, the browser route sits behind the
  dashboard login. This module trusts that.
  """

  require Logger

  alias Wardmast.Release.DeployStatus
  alias Wardmast.Worker.ReleaseEnv

  @tag_re ~r/\Av\d+\.\d+\.\d+\z/
  @unit_prefix "wardmast-deploy-"

  @type error ::
          :invalid_tag
          | :already_running
          | :systemd_unavailable
          | {:cli_missing, String.t()}
          | {:launch_failed, String.t()}

  @doc "Start the deploy of `tag`. Returns the unit it runs in."
  @spec start(term()) :: {:ok, %{unit: String.t(), tag: String.t()}} | {:error, error()}
  def start(tag) when is_binary(tag) do
    with :ok <- validate_tag(tag),
         :ok <- ensure_cli(),
         :ok <- ensure_not_running() do
      launch(tag)
    end
  end

  def start(_), do: {:error, :invalid_tag}

  @doc """
  Which tag a request means: `requested` when given (it still has to be a release
  tag — `start/1` re-checks), else the latest release when `update` (the
  `Wardmast.Release.UpdateCheck.state/0` map) says one is available.
  """
  @spec resolve_tag(String.t() | nil, map()) ::
          {:ok, String.t()} | {:error, :invalid_tag | :no_update}
  def resolve_tag(requested, update) when requested in [nil, ""] do
    case update do
      %{update_available?: true, latest: tag} when is_binary(tag) -> {:ok, tag}
      _ -> {:error, :no_update}
    end
  end

  def resolve_tag(requested, _update) when is_binary(requested) do
    if Regex.match?(@tag_re, requested), do: {:ok, requested}, else: {:error, :invalid_tag}
  end

  def resolve_tag(_requested, _update), do: {:error, :invalid_tag}

  @doc "The deploy-unit name for `tag`."
  @spec unit_name(String.t()) :: String.t()
  def unit_name(tag), do: @unit_prefix <> tag

  @doc "Whether a deploy is in progress (an active deploy unit or a live status record)."
  @spec running?() :: boolean()
  def running?, do: ensure_not_running() != :ok

  # ---- guards ------------------------------------------------------------------

  defp validate_tag(tag) do
    if Regex.match?(@tag_re, tag), do: :ok, else: {:error, :invalid_tag}
  end

  defp ensure_cli do
    path = cli_path()
    if File.regular?(path), do: :ok, else: {:error, {:cli_missing, path}}
  end

  defp ensure_not_running do
    if DeployStatus.running?(DeployStatus.read()) do
      {:error, :already_running}
    else
      case active_jobs() do
        {:ok, []} -> :ok
        {:ok, _units} -> {:error, :already_running}
        :error -> {:error, :systemd_unavailable}
      end
    end
  end

  defp active_jobs do
    if darwin?(), do: active_launchd_jobs(), else: active_units()
  end

  # `launchctl list` prints `PID<TAB>Status<TAB>Label`; PID is `-` once a job has
  # exited. Only a job with a live PID counts as a running deploy.
  defp active_launchd_jobs do
    case run("launchctl", ["list"]) do
      {out, 0} ->
        jobs =
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(fn line ->
            case String.split(line, ~r/\s+/, trim: true) do
              [pid, _status, @unit_prefix <> _] -> pid =~ ~r/\A\d+\z/
              _ -> false
            end
          end)

        {:ok, jobs}

      _ ->
        :error
    end
  end

  defp active_units do
    args = ["--user", "list-units", @unit_prefix <> "*", "--state=active,activating,deactivating"]
    args = args ++ ["--no-legend", "--plain", "--no-pager"]

    case run("systemctl", args) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))}
      _ -> :error
    end
  end

  # ---- launch ------------------------------------------------------------------

  defp launch(tag) do
    if darwin?(), do: launch_launchd(tag), else: launch_systemd(tag)
  end

  defp launch_launchd(tag) do
    unit = unit_name(tag)
    home = Wardmast.Nodes.Agent.data_home()
    plist = Path.join(home, unit <> ".plist")

    with {:ok, domain} <- launchd_domain(),
         :ok <- write_plist(plist, plist_xml(unit, tag, home)),
         # A finished job lingers loaded; it must go before the label can be reused.
         _ = run("launchctl", ["bootout", "#{domain}/#{unit}"]),
         {_out, 0} <- run("launchctl", ["bootstrap", domain, plist]) do
      Logger.info(
        "Wardmast.Release.SelfDeploy: started launchd job #{unit} (arb server deploy --version #{tag})"
      )

      {:ok, %{unit: unit, tag: tag}}
    else
      {:error, reason} ->
        {:error,
         {:launch_failed, scrub_message("could not prepare launchd job: #{inspect(reason)}")}}

      {out, _code} ->
        message = scrub_message(out)
        Logger.warning("Wardmast.Release.SelfDeploy: launchctl bootstrap failed: #{message}")
        {:error, {:launch_failed, message}}
    end
  end

  defp launchd_domain do
    with {out, 0} <- run("id", ["-u"]),
         uid = String.trim(out),
         true <- uid =~ ~r/\A\d+\z/ do
      {:ok, "gui/" <> uid}
    else
      _ -> {:error, :bad_uid}
    end
  end

  defp write_plist(path, xml) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, xml)
  end

  # `$1` is the env file, the rest is the command: nothing from `tag` is ever
  # spliced into the script text.
  @launch_script ~S|set -a; [ -f "$1" ] && . "$1"; set +a; shift; exec "$@"|

  defp plist_xml(unit, tag, home) do
    argv =
      ["/bin/sh", "-c", @launch_script, unit, Path.join(home, "wardmast.env")] ++
        [cli_path(), "server", "deploy", "--version", tag, "--json"]

    env = [
      {"WARDMAST_DATA_HOME", home},
      # The `arb` CLI still reads the pre-rename name.
      {"ARB_DATA_HOME", home},
      {"PATH", System.get_env("PATH") || "/usr/bin:/bin:/usr/sbin:/sbin"}
    ]

    log = Path.join(home, unit <> ".log")
    strings = Enum.map_join(argv, "\n", &"    <string>#{xml(&1)}</string>")

    pairs =
      Enum.map_join(env, "\n", fn {k, v} ->
        "    <key>#{xml(k)}</key>\n    <string>#{xml(v)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{xml(unit)}</string>
      <key>ProgramArguments</key>
      <array>
    #{strings}
      </array>
      <key>EnvironmentVariables</key>
      <dict>
    #{pairs}
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>AbandonProcessGroup</key>
      <true/>
      <key>StandardOutPath</key>
      <string>#{xml(log)}</string>
      <key>StandardErrorPath</key>
      <string>#{xml(log)}</string>
    </dict>
    </plist>
    """
  end

  defp xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp launch_systemd(tag) do
    unit = unit_name(tag)
    home = Wardmast.Nodes.Agent.data_home()

    args =
      [
        "--user",
        "--unit=#{unit}",
        "--collect",
        "--description=Wardmast self-update to #{tag}",
        "--property=EnvironmentFile=-" <> Path.join(home, "wardmast.env"),
        "--setenv=WARDMAST_DATA_HOME=#{home}",
        # The `arb` CLI (renamed in a sibling ticket) still reads ARB_DATA_HOME.
        "--setenv=ARB_DATA_HOME=#{home}",
        cli_path(),
        "server",
        "deploy",
        "--version",
        tag,
        "--json"
      ]

    case run("systemd-run", args) do
      {_out, 0} ->
        Logger.info(
          "Wardmast.Release.SelfDeploy: started #{unit} (arb server deploy --version #{tag})"
        )

        {:ok, %{unit: unit, tag: tag}}

      {out, _code} ->
        classify_failure(out)
    end
  end

  # Two near-simultaneous requests race for the same unit name; the loser reads
  # as "already running", not as a launch failure.
  defp classify_failure(out) do
    if out =~ ~r/already (loaded|exists)|already.*fragment/i do
      {:error, :already_running}
    else
      message = scrub_message(out)
      Logger.warning("Wardmast.Release.SelfDeploy: systemd-run failed: #{message}")
      {:error, {:launch_failed, message}}
    end
  end

  # ---- helpers -----------------------------------------------------------------

  defp cli_path do
    case config(:arb_path) do
      path when is_binary(path) ->
        path

      _ ->
        case System.get_env("ARB_INSTALL_BIN") do
          path when is_binary(path) and path != "" -> Path.expand(path)
          _ -> Path.join(System.user_home!(), ".local/bin/arb")
        end
    end
  end

  # `:cmd` is the test seam (`config :wardmast, :self_deploy, cmd: fun`); the real
  # runner is `ReleaseEnv.cmd/3`, which strips the release's ROOTDIR/BINDIR/RELEASE_*
  # so nothing of this BEAM leaks into what systemd-run spawns.
  defp run(cmd, args) do
    case config(:cmd) do
      fun when is_function(fun, 3) -> fun.(cmd, args, stderr_to_stdout: true)
      _ -> ReleaseEnv.cmd(cmd, args, stderr_to_stdout: true)
    end
  rescue
    e in ErlangError -> {"could not run #{cmd}: #{inspect(e.original)}", 127}
  end

  defp scrub_message(out) do
    out |> to_string() |> String.trim() |> scrub() |> String.slice(0, 400)
  end

  # `:os` is a test seam alongside `:cmd` (an `:os.type/0` tuple).
  defp darwin?, do: match?({:unix, :darwin}, config(:os) || :os.type())

  defp scrub(text) do
    case Wardmast.SecretRefs.External.env_value("GITHUB_TOKEN") do
      token when is_binary(token) and byte_size(token) >= 8 ->
        String.replace(text, token, "[redacted]")

      _ ->
        text
    end
  end

  defp config(key), do: :wardmast |> Application.get_env(:self_deploy, []) |> Keyword.get(key)
end
