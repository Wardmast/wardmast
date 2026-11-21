defmodule Wardmast.Quota.GrantRefresher do
  @moduledoc """
  Keeps the quota poller's **dedicated Claude grant** alive with no
  interactive session (bd-b632tz).

  `/api/oauth/usage` only accepts a `user:profile`-scoped
  `claudeAiOauth.accessToken` — the account's setup token is locked out
  (`docs/oauth-usage-ratelimit.md`). That access token lasts ~8h, and only the
  `claude` CLI refreshes it. So the operator logs in once into a config dir of
  its own (`CLAUDE_CONFIG_DIR=~/.wardmast/quota-claude claude auth login` — an
  independent grant with its own refresh token, so its rotation never touches
  the operator's `~/.claude` session), references it from the account with a
  `:cli_credentials_path` credential, and this process has the CLI refresh it
  when it is about to expire. `Wardmast.Quota.CloudProbe` reads the file's
  token fresh on every poll.

  ## Refresh by CLI, never by Wardmast

  Wardmast never calls the OAuth token endpoint itself — that would mean
  impersonating Claude Code's OAuth client. It runs a minimal `claude -p`
  with `CLAUDE_CONFIG_DIR` pointed at the grant's config dir and lets the CLI
  refresh (and rotate) the file in place. Wardmast only ever reads the file.

  The CLI refreshes **only when the access token is within 5 minutes of
  expiry** (or already expired) — measured, see
  `docs/oauth-usage-ratelimit.md`: a `claude -p` 44 minutes before expiry
  leaves `expiresAt` untouched. So this runs the CLI once `expiresAt` is
  inside `:refresh_window_ms` (default 4 minutes, inside the CLI's own
  window with room for tick jitter), checking every `:interval_ms` (default
  60s). A refresh counts as done only if the re-read file's `expiresAt`
  moved later; a non-zero exit or an unmoved `expiresAt` is a failure,
  retried after `:failure_backoff_ms` (default 5 minutes).

  The run strips `CLAUDE_CODE_OAUTH_TOKEN` and the other auth-overriding
  variables from its env, so the CLI authenticates off (and so refreshes)
  the grant file rather than a token the server happens to carry.

  ## One refresher per grant

  A rotating grant is refreshed by exactly one process (bd-6y4pj6): two
  refreshers of one refresh token rotate each other out and invalidate the
  grant, which is what blinded the quota poll on 2026-11-20. Within this
  process the GenServer serialises every check; across processes (a second
  node, a restarted server overlapping its predecessor) `refresh/3` takes an
  exclusive lock — an atomic `mkdir` of `.refresh.lock` beside the grant —
  before running the CLI, and re-reads the grant under it, so a consumer that
  lost the race sees the winner's fresh `expiresAt` and does nothing. A lock
  older than the CLI's hard timeout (plus slack) is a crashed holder's and is
  taken over. Nothing else in Wardmast reads or writes this file for
  authentication: sessions use the account's setup token
  (`Wardmast.Sessions.AccountCredentials`), never a copy of it.

  ## Neutral cwd

  The CLI runs from `:cwd` (default `<scratch_root>/quota-grant-refresh`) —
  never the coordinator dir, where a `claude` session reads the coordinator's
  instructions and becomes one, and never a repo. `neutral_cwd?/1` enforces
  it: no `.git`, `CLAUDE.md` or `AGENTS.md` in the directory or any
  ancestor, and not under the primary checkout. A non-neutral cwd is a
  refresh failure; the CLI does not run.

  ## Escalation

  Exactly one mailbox item per episode, via
  `Wardmast.Messages.CoordinatorNotifier.quota_grant_failing/3`, which names
  the re-login command:

    * a failed refresh or an unreadable grant — once, until the grant is
      healthy again (a refresh succeeds, or a fresh `expiresAt` shows the
      operator logged in again);
    * a `refreshTokenExpiresAt` within `:refresh_token_warning_ms` (default 2
      days) — once per distinct `refreshTokenExpiresAt`.

  ## Configuration

  `config :wardmast, :quota_grant_refresher` — `:enabled` (default `true`,
  `false` in test), `:interval_ms`, `:refresh_window_ms`,
  `:refresh_token_warning_ms`, `:failure_backoff_ms`, `:cli_timeout_ms`,
  `:claude_cmd`, `:cwd`. Tests also pass `:grants_fun` (defaults to
  `Wardmast.Accounts.Credentials.quota_grants/0`).
  """

  use GenServer
  require Logger

  alias Wardmast.Accounts.Credentials
  alias Wardmast.Config.Paths
  alias Wardmast.Messages.CoordinatorNotifier
  alias Wardmast.Quota.GrantFile
  alias Wardmast.Worker.ReleaseEnv
  alias Wardmast.Worker.SpawnEnv
  alias Wardmast.Worker.Timeout

  @default_interval_ms 60_000
  @default_refresh_window_ms 4 * 60_000
  @default_refresh_token_warning_ms 2 * 24 * 3_600_000
  @default_failure_backoff_ms 5 * 60_000
  @default_cli_timeout_ms 120_000

  # The cheapest invocation that goes through the CLI's token-refresh path: a
  # one-word print-mode turn on the smallest model, with no tools, no MCP
  # servers and nothing written to session history.
  @cli_args [
    "-p",
    "Reply with just: ok",
    "--model",
    "haiku",
    "--no-session-persistence",
    "--strict-mcp-config",
    "--tools",
    ""
  ]

  @agent_instruction_files ~w(.git CLAUDE.md AGENTS.md)

  defmodule State do
    @moduledoc false
    defstruct [
      :enabled,
      :interval_ms,
      :refresh_window_ms,
      :refresh_token_warning_ms,
      :failure_backoff_ms,
      :cli_timeout_ms,
      :claude_cmd,
      :cwd,
      :grants_fun,
      grants: %{}
    ]
  end

  # ---- public API --------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Run one check of every grant now and wait for it (tests, `iex`)."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc """
  Per-grant status, keyed by path: `%{status: :ok | :failing | :pending,
  expires_at:, refresh_token_expires_at:, last_refresh_at:}`.
  """
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc """
  Whether `dir` is a safe cwd for a `claude` run: no `.git`, `CLAUDE.md` or
  `AGENTS.md` in it or any ancestor (not a repo, not the coordinator dir or
  anything else that would hand the session agent instructions), and not
  under the primary checkout.
  """
  @spec neutral_cwd?(String.t()) :: boolean()
  def neutral_cwd?(dir) when is_binary(dir) do
    expanded = Path.expand(dir)
    not instructed_ancestor?(expanded) and not under_primary_checkout?(expanded)
  end

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    state = %State{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      refresh_window_ms: cfg(:refresh_window_ms, opts, @default_refresh_window_ms),
      refresh_token_warning_ms:
        cfg(:refresh_token_warning_ms, opts, @default_refresh_token_warning_ms),
      failure_backoff_ms: cfg(:failure_backoff_ms, opts, @default_failure_backoff_ms),
      cli_timeout_ms: cfg(:cli_timeout_ms, opts, @default_cli_timeout_ms),
      claude_cmd: cfg(:claude_cmd, opts, "claude"),
      cwd: cfg(:cwd, opts, nil),
      grants_fun: Keyword.get(opts, :grants_fun, &Credentials.quota_grants/0)
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, %State{} = state), do: {:reply, :ok, check_all(state)}

  def handle_call(:state, _from, %State{} = state) do
    grants =
      Map.new(state.grants, fn {path, g} ->
        {path, Map.take(g, [:status, :expires_at, :refresh_token_expires_at, :last_refresh_at])}
      end)

    {:reply, %{enabled: state.enabled, grants: grants}, state}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    state = if state.enabled, do: check_all(state), else: state
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- checks ------------------------------------------------------------

  defp check_all(%State{} = state) do
    paths = state.grants_fun.() |> Enum.map(& &1.path) |> Enum.uniq()

    grants =
      Map.new(paths, fn path ->
        {path, check(path, Map.get(state.grants, path, fresh_entry()), state)}
      end)

    %{state | grants: grants}
  rescue
    e ->
      Logger.warning("Wardmast.Quota.GrantRefresher: check raised: #{Exception.message(e)}")
      state
  end

  defp fresh_entry do
    %{
      status: :pending,
      expires_at: nil,
      refresh_token_expires_at: nil,
      last_refresh_at: nil,
      last_failure_at: nil,
      escalated_failure?: false,
      warned_refresh_token_expiry: nil
    }
  end

  defp check(path, entry, state) do
    case GrantFile.read(path) do
      {:ok, grant} ->
        entry
        |> Map.merge(%{
          expires_at: grant.expires_at,
          refresh_token_expires_at: grant.refresh_token_expires_at
        })
        |> warn_refresh_token_expiry(grant, state)
        |> maybe_refresh(grant, state)

      {:error, reason} ->
        fail(entry, path, {:unreadable, reason})
    end
  end

  defp warn_refresh_token_expiry(entry, %GrantFile{refresh_token_expires_at: nil}, _state),
    do: entry

  defp warn_refresh_token_expiry(entry, %GrantFile{} = grant, state) do
    at = grant.refresh_token_expires_at

    if ms_until(at) <= state.refresh_token_warning_ms and
         entry.warned_refresh_token_expiry != at do
      escalate(grant.path, {:refresh_token_expiring, at})
      %{entry | warned_refresh_token_expiry: at}
    else
      entry
    end
  end

  # No `expiresAt` to judge by: leave the grant to the CLI's own devices.
  defp maybe_refresh(entry, %GrantFile{expires_at: nil}, _state), do: entry

  defp maybe_refresh(entry, %GrantFile{} = grant, state) do
    cond do
      ms_until(grant.expires_at) > state.refresh_window_ms ->
        # Healthy — which is also how a re-login shows up after a failure.
        recovered(entry)

      backing_off?(entry, state) ->
        entry

      true ->
        refresh(entry, grant, state)
    end
  end

  defp backing_off?(%{status: :failing, last_failure_at: %DateTime{} = at}, state),
    do: DateTime.diff(DateTime.utc_now(), at, :millisecond) < state.failure_backoff_ms

  defp backing_off?(_entry, _state), do: false

  defp refresh(entry, %GrantFile{path: path}, state) do
    case acquire_lock(path, state) do
      :ok ->
        try do
          refresh_locked(entry, path, state)
        after
          release_lock(path)
        end

      :busy ->
        # Another process is refreshing this very grant right now; its result
        # shows on the next tick. Neither a failure nor a second refresh.
        Logger.debug("Wardmast.Quota.GrantRefresher: #{path} is being refreshed elsewhere")
        entry
    end
  end

  # Under the lock: the grant may have been renewed by whoever held it before
  # us, so look again before spending a CLI run.
  defp refresh_locked(entry, path, state) do
    case GrantFile.read(path) do
      {:ok, %GrantFile{expires_at: %DateTime{} = at} = grant} ->
        if ms_until(at) > state.refresh_window_ms do
          %{
            recovered(entry)
            | expires_at: at,
              refresh_token_expires_at: grant.refresh_token_expires_at
          }
        else
          run_refresh(entry, grant, state)
        end

      {:ok, grant} ->
        run_refresh(entry, grant, state)

      {:error, reason} ->
        fail(entry, path, {:unreadable, reason})
    end
  end

  defp run_refresh(entry, %GrantFile{path: path} = grant, state) do
    with {:ok, cwd} <- neutral_cwd(state),
         :ok <- run_cli(path, cwd, state),
         {:ok, renewed} <- reread(path),
         :ok <- expiry_moved(grant, renewed) do
      Logger.info(
        "Wardmast.Quota.GrantRefresher: renewed #{path}; access token now expires " <>
          "#{DateTime.to_iso8601(renewed.expires_at)}"
      )

      %{
        recovered(entry)
        | expires_at: renewed.expires_at,
          refresh_token_expires_at: renewed.refresh_token_expires_at,
          last_refresh_at: DateTime.utc_now()
      }
    else
      {:error, reason} -> fail(entry, path, reason)
    end
  end

  defp recovered(entry), do: %{entry | status: :ok, escalated_failure?: false}

  defp fail(entry, path, reason) do
    Logger.warning(
      "Wardmast.Quota.GrantRefresher: quota grant #{path} could not be kept fresh: " <>
        inspect(reason)
    )

    unless entry.escalated_failure?, do: escalate(path, {:refresh_failed, reason})

    %{entry | status: :failing, last_failure_at: DateTime.utc_now(), escalated_failure?: true}
  end

  defp reread(path) do
    case GrantFile.read(path) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, {:unreadable_after_refresh, reason}}
    end
  end

  defp expiry_moved(%GrantFile{expires_at: before}, %GrantFile{expires_at: %DateTime{} = now})
       when not is_nil(before) do
    if DateTime.compare(now, before) == :gt,
      do: :ok,
      else: {:error, "the CLI ran but the grant's expiresAt did not move"}
  end

  defp expiry_moved(_before, _after),
    do: {:error, "the CLI ran but the grant's expiresAt did not move"}

  # ---- the refresh lock --------------------------------------------------

  defp lock_path(path), do: Path.join(GrantFile.config_dir(path), ".refresh.lock")

  # `File.mkdir/1` is atomic: exactly one caller creates the directory.
  defp acquire_lock(path, state) do
    lock = lock_path(path)

    case File.mkdir(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if lock_stale?(lock, state) do
          _ = File.rm_rf(lock)
          if File.mkdir(lock) == :ok, do: :ok, else: :busy
        else
          :busy
        end

      {:error, _} ->
        :busy
    end
  end

  defp release_lock(path), do: File.rm_rf(lock_path(path))

  # A holder that outlived the CLI's own hard timeout is gone.
  defp lock_stale?(lock, state) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.os_time(:second) - mtime > div(state.cli_timeout_ms, 1000) + 60

      _ ->
        false
    end
  end

  # ---- the CLI run -------------------------------------------------------

  defp neutral_cwd(%State{cwd: configured}) do
    cwd = Path.expand(configured || Path.join(Paths.scratch_root(), "quota-grant-refresh"))

    cond do
      not neutral_cwd?(cwd) -> {:error, {:cwd_not_neutral, cwd}}
      match?({:error, _}, File.mkdir_p(cwd)) -> {:error, {:cwd_unavailable, cwd}}
      true -> {:ok, cwd}
    end
  end

  # `timeout -k` gives the CLI a hard OS-side deadline independent of whether
  # Erlang is still waiting on it (mirrors `Wardmast.Quota.CloudCode`), and
  # output goes to /dev/null at the shell level so a lingering grandchild
  # holding the pipe can't wedge the port. Only the exit status matters: the
  # refresh is judged by re-reading the grant file.
  defp run_cli(path, cwd, state) do
    case System.find_executable(state.claude_cmd) do
      nil ->
        {:error, {:executable_not_found, state.claude_cmd}}

      exe ->
        timeout_s = max(1, ceil(state.cli_timeout_ms / 1000))

        # bd-7r0qrj: anything that would make the CLI authenticate some other
        # way than the grant file in `CLAUDE_CONFIG_DIR` (an inherited
        # CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_* / Bedrock / Vertex var) skips the
        # refresh; the allowlist drops all of those, so only the dir is added.
        env = SpawnEnv.cmd_env([{"CLAUDE_CONFIG_DIR", GrantFile.config_dir(path)}], "claude")

        task =
          Task.async(fn ->
            ReleaseEnv.cmd(
              "/bin/sh",
              [
                "-c",
                ~s(exec #{Timeout.shell_prefix(timeout_s, kill_after: 5)}"$0" "$@" >/dev/null 2>&1 </dev/null),
                exe | @cli_args
              ],
              cd: cwd,
              env: env
            )
          end)

        case Task.yield(task, state.cli_timeout_ms + 10_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {_out, status}} when status in [124, 137] -> {:error, :cli_timeout}
          {:ok, {_out, status}} -> {:error, {:cli_exit, status}}
          _ -> {:error, :cli_timeout}
        end
    end
  end

  # ---- escalation --------------------------------------------------------

  defp escalate(path, cause) do
    case primary_workspace_id() do
      nil -> :ok
      ws_id -> CoordinatorNotifier.quota_grant_failing(%{workspace_id: ws_id}, path, cause)
    end
  rescue
    e ->
      Logger.warning("Wardmast.Quota.GrantRefresher: escalation raised: #{Exception.message(e)}")
  end

  # The oldest workspace, as `Wardmast.Agents.CredentialWatchdog` picks it: the
  # grant is install-wide, so one stable mailbox per episode.
  defp primary_workspace_id do
    Wardmast.Tasks.Workspace
    |> Ash.read!()
    |> Enum.map(& &1.id)
    |> Enum.min(&<=/2, fn -> nil end)
  end

  # ---- helpers -----------------------------------------------------------

  defp instructed_ancestor?(dir) do
    Enum.any?(ancestors(dir), fn d ->
      Enum.any?(@agent_instruction_files, &File.exists?(Path.join(d, &1)))
    end)
  end

  defp ancestors(dir) do
    Stream.unfold(dir, fn
      nil -> nil
      d -> {d, if(Path.dirname(d) == d, do: nil, else: Path.dirname(d))}
    end)
  end

  defp under_primary_checkout?(dir) do
    case Paths.primary_checkout() do
      nil -> false
      checkout -> dir == checkout or String.starts_with?(dir, checkout <> "/")
    end
  end

  defp ms_until(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :millisecond)

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp cfg(key, opts, default) do
    Keyword.get_lazy(opts, key, fn ->
      :wardmast
      |> Application.get_env(:quota_grant_refresher, [])
      |> Keyword.get(key, default)
    end)
  end
end
