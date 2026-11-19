defmodule Wardmast.Boot.LoginShellPath do
  @moduledoc """
  Resolve `PATH` from the operator's login shell, once, at boot (bd-5wfsj7).

  A server launched from a GUI (a launchd agent, a desktop entry) inherits the
  session manager's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`): nothing the
  operator installed with Homebrew, npm, nvm, mise or `~/.local/bin` — which is
  where the agent CLIs live — is on it. The server would report every CLI as
  missing and every spawn would fail to find its binary.

  `run/1`, called from `Wardmast.Application.start/2` before any child starts,
  detects that case (`minimal?/1`: no dir beyond the four system ones) and asks
  `$SHELL -l -i -c` for the `PATH` its rc files build. The answer, framed by
  markers so rc-file chatter cannot corrupt it, replaces the VM's `PATH`
  (`System.put_env/2`; the dirs the server already had are kept, after the
  shell's). Everything downstream then agrees on one `PATH`: `System.find_executable/1`
  in the agent adapters, `Wardmast.Agents.CliDetection`, and the env a worker is
  spawned with (`Wardmast.Worker.SpawnEnv`, whose allowlist inherits `PATH`).

  It runs at most once per boot and never at all when the `PATH` is already
  richer than the GUI default (a terminal launch, a systemd unit that sets its
  own), so a hand-built `PATH` is never second-guessed. A shell that fails, hangs
  past the timeout or prints no markers leaves `PATH` untouched; the reason is
  kept for `info/0` and logged. `config :wardmast, #{inspect(__MODULE__)}, enabled:
  false` (the test config) turns it off.
  """

  require Logger

  alias Wardmast.Worker.ReleaseEnv

  @start "__WARDMAST_PATH_START__"
  @end_marker "__WARDMAST_PATH_END__"
  @default_timeout_ms 5_000
  @system_dirs ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
  @key {__MODULE__, :info}

  @type info :: %{
          source: :login_shell | :inherited,
          shell: String.t() | nil,
          added: [String.t()],
          reason: term()
        }

  @doc """
  Resolve and apply once. Options (all for tests): `:enabled`, `:path` (the
  current `PATH`), `:shell`, `:timeout_ms`, `:put_env` (a 1-arity fun taking the new
  `PATH`; default `System.put_env("PATH", _)`).

  `{:applied, info}` or `{:skipped, reason}`; either way the outcome is kept for
  `info/0`.
  """
  @spec run(keyword()) :: {:applied, info()} | {:skipped, term()}
  def run(opts \\ []) do
    outcome = do_run(opts)
    :persistent_term.put(@key, record(outcome))
    log(outcome)
    outcome
  end

  @doc "What `run/1` did this boot (`source: :inherited` when it did nothing)."
  @spec info() :: info()
  def info,
    do: :persistent_term.get(@key, %{source: :inherited, shell: nil, added: [], reason: nil})

  @doc "True when `path` holds no dir beyond the GUI-session defaults."
  @spec minimal?(String.t() | nil) :: boolean()
  def minimal?(path) do
    (path || "") |> String.split(":", trim: true) |> Enum.all?(&(&1 in @system_dirs))
  end

  @doc """
  Ask `shell` (`-l -i -c`) for its `PATH`. `{:ok, path}` or `{:error, reason}`:
  `:no_shell`, `:timeout`, `{:exit, status}` or `:no_path_in_output`.
  """
  @spec resolve(String.t() | nil, pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def resolve(shell, timeout_ms \\ @default_timeout_ms)
  def resolve(nil, _timeout_ms), do: {:error, :no_shell}

  def resolve(shell, timeout_ms) when is_binary(shell) do
    if File.regular?(shell), do: ask(shell, timeout_ms), else: {:error, :no_shell}
  end

  # ---- internals --------------------------------------------------------------

  defp do_run(opts) do
    current = Keyword.get_lazy(opts, :path, fn -> System.get_env("PATH") end)

    cond do
      not Keyword.get_lazy(opts, :enabled, &enabled?/0) -> {:skipped, :disabled}
      not minimal?(current) -> {:skipped, :path_not_minimal}
      true -> apply_login_path(current, opts)
    end
  end

  defp apply_login_path(current, opts) do
    shell = Keyword.get_lazy(opts, :shell, &default_shell/0)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    put_env = Keyword.get(opts, :put_env, &System.put_env("PATH", &1))

    case resolve(shell, timeout) do
      {:ok, login_path} ->
        have = split(current)
        merged = Enum.uniq(split(login_path) ++ have)
        put_env.(Enum.join(merged, ":"))

        {:applied, %{source: :login_shell, shell: shell, added: merged -- have, reason: nil}}

      {:error, :no_shell} ->
        {:skipped, :no_shell}

      {:error, reason} ->
        {:skipped, {:resolve_failed, reason}}
    end
  end

  defp split(path), do: String.split(path || "", ":", trim: true)

  defp enabled? do
    :wardmast |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end

  defp default_shell do
    case System.get_env("SHELL") do
      shell when shell in [nil, ""] ->
        if match?({:unix, :darwin}, :os.type()), do: "/bin/zsh"

      shell ->
        shell
    end
  end

  # `-l -i`: PATH is often built in `.zshrc`/`.bashrc` (interactive), not only in
  # the login profile. The script is a literal; `shell` is `$SHELL` or the macOS
  # default, never request input. Through `ReleaseEnv.cmd/3` so the child does not
  # inherit the release's ROOTDIR/BINDIR/RELEASE_*.
  defp ask(shell, timeout_ms) do
    script = ~s(printf '%s' "#{@start}${PATH}#{@end_marker}")

    task =
      Task.async(fn ->
        ReleaseEnv.cmd(shell, ["-l", "-i", "-c", script], stderr_to_stdout: false)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> extract(output)
      {:ok, {_output, status}} -> {:error, {:exit, status}}
      _ -> {:error, :timeout}
    end
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp extract(output) do
    case Regex.run(~r/#{@start}(.*?)#{@end_marker}/s, output, capture: :all_but_first) do
      [path] when path != "" -> {:ok, path}
      _ -> {:error, :no_path_in_output}
    end
  end

  defp record({:applied, info}), do: info

  defp record({:skipped, reason}),
    do: %{source: :inherited, shell: nil, added: [], reason: reason}

  defp log({:applied, %{shell: shell, added: added}}),
    do:
      Logger.info(
        "LoginShellPath: GUI-minimal PATH replaced from #{shell} -l -i (added #{Enum.join(added, ", ")})"
      )

  defp log({:skipped, {:resolve_failed, reason}}),
    do:
      Logger.warning(
        "LoginShellPath: PATH is minimal but the login shell gave no PATH (#{inspect(reason)}); " <>
          "agent CLIs outside the system dirs will not be found"
      )

  defp log({:skipped, _reason}), do: :ok
end
