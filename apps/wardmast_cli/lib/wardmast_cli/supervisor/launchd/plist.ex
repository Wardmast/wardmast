defmodule WardmastCli.Supervisor.Launchd.Plist do
  @moduledoc """
  Pure generators for the launchd side of `WardmastCli.Supervisor.Launchd`:
  the LaunchAgent property list and the shell wrapper it runs.

  launchd has no `EnvironmentFile=`, so the plist does not exec the server
  directly. It runs `<arbiter_home>/launchd-run.sh`, which loads
  `<arbiter_home>/wardmast.env` (captured secrets and `PATH`, written by
  `arb install service` and refreshed by every `arb server deploy`; read as
  literal `KEY=value` lines) and then execs the checkout's `.run-server.sh`
  (which in turn sources the checkout's own `.wardmast.env`) in dev mode, or
  `<arbiter_home>/current/bin/wardmast start` for a release install. Every hop is an
  `exec`, so the PID launchd tracks is the BEAM.

  The plist mirrors the systemd unit's behaviour:

    * `RunAtLoad` — start when the agent is loaded (login / `bootstrap`).
    * `KeepAlive = {SuccessfulExit = false}` — `Restart=on-failure`: respawn
      after a crash, leave a clean exit and `launchctl bootout` alone.
    * `ThrottleInterval = 10` — `RestartSec=10`.
    * `StandardOutPath`/`StandardErrorPath` — the same `log/wardmast.log` the
      user unit appends to.
    * `AbandonProcessGroup = false` (explicit) — phase 1: when the service
      stops, launchd also kills everything left in its process group. Workers
      do not yet survive a server restart on macOS.
  """

  @label "com.wardmast.server"
  @wrapper_name "launchd-run.sh"
  @throttle_s 10

  # launchd starts agents with a minimal PATH (no Homebrew). This is only the
  # fallback; the PATH captured into wardmast.env wins once the wrapper sources it.
  @default_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  @doc "The launchd job label."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The plist file name (`<label>.plist`)."
  @spec file_name() :: String.t()
  def file_name, do: @label <> ".plist"

  @doc "Where the env-sourcing wrapper script lives."
  @spec wrapper_path(String.t()) :: String.t()
  def wrapper_path(arbiter_home), do: Path.join(arbiter_home, @wrapper_name)

  @doc "Path of the log file launchd appends stdout and stderr to."
  @spec log_path(String.t()) :: String.t()
  def log_path(arbiter_home), do: Path.join([arbiter_home, "log", "wardmast.log"])

  @doc """
  The LaunchAgent plist.

  Options: `:arbiter_home`, `:env` (a list of extra `{name, value}` pairs to
  forward, e.g. `WARDMAST_HOST`) and, for a dev checkout, `:root`. Without
  `:root` this is the **release-mode** plist: the working directory is the data
  home and the wrapper execs `<arbiter_home>/current/bin/wardmast start`, so
  `arb server deploy`'s symlink swap + restart is all it takes to change
  versions (the same contract as the systemd release unit).
  """
  @spec plist(keyword()) :: String.t()
  def plist(opts) do
    arbiter_home = Keyword.fetch!(opts, :arbiter_home)
    extra_env = Keyword.get(opts, :env, [])
    log = log_path(arbiter_home)

    # Dev mode runs from the checkout; release mode (no `:root`) from the data home.
    {workdir, env} =
      case Keyword.get(opts, :root) do
        nil -> {arbiter_home, [{"PATH", @default_path}] ++ extra_env}
        root -> {root, [{"PATH", @default_path}, {"ARB_HOME", root}] ++ extra_env}
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{esc(@label)}</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/sh</string>
        <string>#{esc(wrapper_path(arbiter_home))}</string>
      </array>
      <key>WorkingDirectory</key>
      <string>#{esc(workdir)}</string>
      <key>EnvironmentVariables</key>
      <dict>
    #{env_entries(env)}
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>ThrottleInterval</key>
      <integer>#{@throttle_s}</integer>
      <key>AbandonProcessGroup</key>
      <false/>
      <key>StandardOutPath</key>
      <string>#{esc(log)}</string>
      <key>StandardErrorPath</key>
      <string>#{esc(log)}</string>
    </dict>
    </plist>
    """
  end

  @doc """
  The wrapper `ProgramArguments` runs: export each `KEY=value` line of
  `wardmast.env` (if present) literally — it is a systemd-style file, not shell
  syntax — then `cd` to the checkout and `exec` its `.run-server.sh`.
  """
  @spec wrapper_script(keyword()) :: String.t()
  def wrapper_script(opts) do
    arbiter_home = Keyword.fetch!(opts, :arbiter_home)
    env_file = arbiter_home |> Path.join("wardmast.env") |> sq()

    {workdir, launch} =
      case Keyword.get(opts, :root) do
        nil ->
          {arbiter_home, "exec #{sq(release_bin(arbiter_home))} start"}

        root ->
          {root, "exec /bin/sh #{sq(Path.join(root, ".run-server.sh"))}"}
      end

    """
    #!/bin/sh
    # Generated by `arb install service` (launchd backend). launchd has no
    # EnvironmentFile=, so load the captured secrets/PATH here, then hand over
    # to the checkout's launcher. Regenerated on every install.
    set -e
    # wardmast.env is written for systemd's EnvironmentFile= (bare KEY=value,
    # no quoting), not for the shell: dot-sourcing it would split a PATH with
    # a space and expand $ or backticks. Export each line literally instead.
    env_file=#{env_file}
    if [ -f "$env_file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ''|'#'*) ;;
          [A-Za-z_]*=*)
            case "${line%%=*}" in
              *[!A-Za-z0-9_]*) ;;
              *) export "$line" ;;
            esac
            ;;
        esac
      done < "$env_file"
    fi
    cd #{sq(workdir)}
    #{launch}
    """
  end

  @doc "The release binary the release-mode wrapper execs (through the `current` symlink)."
  @spec release_bin(String.t()) :: String.t()
  def release_bin(arbiter_home), do: Path.join([arbiter_home, "current", "bin", "wardmast"])

  defp env_entries(env) do
    env
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {k, v} ->
      "    <key>#{esc(k)}</key>\n    <string>#{esc(v)}</string>"
    end)
  end

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # POSIX single-quote: close, escaped quote, reopen.
  defp sq(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
