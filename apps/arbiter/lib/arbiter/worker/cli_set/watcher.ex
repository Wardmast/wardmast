defmodule Arbiter.Worker.CliSet.Watcher do
  @moduledoc """
  Eager republish when the CLI set moves (SI2, OD13, `docs/design/remote-workers.md`
  §21.9): a new upstream CLI should reach every node and pod promptly, not on the
  next dispatch of each repo.

  It looks at the set (`Arbiter.Worker.CliSet.resolve/1`) at boot, every 10
  minutes, and on SI1a's `cli_version_bumped` event (`Bump` rewrites
  `worker.cli.versions`, announced as `{:installation_settings_changed,
  :worker_cli_versions}`). When the set's content hash differs from the one it
  last republished for (or it has not republished yet this boot), it calls
  `Arbiter.Worker.Image.Publisher.ensure_ready/2` again for every repo in
  `Arbiter.Worker.Image.PublishLedger` that published within the last 14 days,
  so a repo nobody has used for a fortnight is left for its next dispatch.
  A bump with identical bytes moves nothing.

  Transient failures (podman exit 125 with a registry ping, DNS or connection
  error, registry reachability failure, or a timeout) are retried with backoff
  (`1m`, `5m`, `15m`, then `1h` capped). Non-transient failures (auth or 4xx
  denied) do not loop and are surfaced immediately as a persistent failure in
  `status/1` (reported by `arb server doctor`) and as a coordinator inbox notice.

  While `worker.cli_set.hold` is set it does nothing: the held set is what is
  published, and the auto-bump is suspended (`Bump`).

  ## Options

  `:name`, `:interval_ms` (default 10 minutes), `:boot_delay_ms` (default 30
  seconds; `:infinity` skips the boot run), `:retry_schedule_ms` (default
  `[1m, 5m, 15m, 1h]`), `:days` (default 14), `:publish`
  (`fn ctx -> result end`, default `Publisher.ensure_ready/2`; a test seam),
  `:probe` (`fn target -> :ok | {:error, reason} end`, registry reachability gate),
  and `:cli_opts`, `:ledger`, `:now`, passed through to the set resolver and the
  ledger. `config :arbiter, :cli_set_watcher, enabled: false` keeps it from
  starting (the test suite).
  """

  use GenServer

  alias Arbiter.Messages.Message
  alias Arbiter.Quota
  alias Arbiter.Settings
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.Image.Publisher
  alias Arbiter.Worker.Image.Publisher.Pipeline
  alias Arbiter.Worker.Image.PublishLedger
  alias Arbiter.Worker.Image.Registry

  require Logger

  @interval_ms :timer.minutes(10)
  @boot_delay_ms :timer.seconds(30)
  @retry_schedule_ms [
    :timer.minutes(1),
    :timer.minutes(5),
    :timer.minutes(15),
    :timer.hours(1)
  ]
  @persistent_transient_threshold 3
  @days 14

  @permanent_patterns [
    "unauthorized",
    "authentication required",
    "unauthenticated",
    "access denied",
    "denied:",
    "resource is denied",
    "permission_denied",
    "permission denied",
    "not allowed",
    "forbidden",
    "status code 401",
    "status code 403",
    "http 401",
    "http 403",
    "401 unauthorized",
    "403 forbidden",
    "invalid username",
    "bad credentials",
    "no registry login is configured"
  ]

  @transient_patterns [
    "pinging container registry",
    "temporary failure in name resolution",
    "name resolution",
    "no such host",
    "lookup ",
    "nxdomain",
    "econnrefused",
    "econnreset",
    "etimedout",
    "ehostunreach",
    "enetunreach",
    "connection refused",
    "connection reset",
    "network is unreachable",
    "no route to host",
    "broken pipe",
    "i/o timeout",
    "timed out",
    "timeout",
    "deadline exceeded",
    "tls handshake",
    "unexpected eof",
    "eof",
    "500 internal server error",
    "502 bad gateway",
    "503 service unavailable",
    "504 gateway timeout",
    "status code 500",
    "status code 502",
    "status code 503",
    "status code 504",
    "status code 429",
    "too many requests",
    "try again"
  ]

  @type outcome ::
          :held
          | :unchanged
          | {:error, term()}
          | {:republished, [{term(), term()}]}

  @type status_snapshot :: %{
          last_hash: String.t() | nil,
          retries: map(),
          failed: map()
        }

  @empty_status %{last_hash: nil, retries: %{}, failed: %{}}

  def start_link(opts \\ []) do
    enabled? =
      Keyword.get_lazy(opts, :enabled, fn ->
        :arbiter |> Application.get_env(:cli_set_watcher, []) |> Keyword.get(:enabled, true)
      end)

    if enabled? do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    else
      :ignore
    end
  end

  @doc "Look at the set now and republish if it moved; returns what happened."
  @spec run_now(GenServer.server()) :: outcome()
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, :infinity)

  @doc "Current watcher retry and persistent-failure snapshot (for doctor and tests)."
  @spec status(GenServer.server()) :: status_snapshot()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 5_000)
  catch
    :exit, _ -> @empty_status
  end

  @doc "Backoff delay in ms for the `attempt`-th failure (1-indexed), capped at the last entry."
  @spec backoff_ms(pos_integer(), [non_neg_integer()] | :infinity) ::
          non_neg_integer() | :infinity
  def backoff_ms(attempt, schedule \\ @retry_schedule_ms)
  def backoff_ms(_attempt, :infinity), do: :infinity
  def backoff_ms(_attempt, []), do: :infinity

  def backoff_ms(attempt, schedule) when is_integer(attempt) and attempt >= 1 do
    Enum.at(schedule, attempt - 1) || List.last(schedule)
  end

  @doc "Classify a publish failure reason as `:transient` (retry with backoff) or `:permanent`."
  @spec classify_error(term()) :: :transient | :permanent
  def classify_error({:error, reason}), do: classify_error(reason)
  def classify_error({:still_publishing, _}), do: :transient
  def classify_error({:timeout, _}), do: :transient
  def classify_error(:timeout), do: :transient
  def classify_error(:publisher_busy), do: :transient
  def classify_error(:publisher_not_running), do: :transient
  def classify_error({:registry_unreachable, _, _}), do: :transient
  def classify_error({:registry_unreachable, _}), do: :transient
  def classify_error({:unreachable, _}), do: :transient
  def classify_error(:unreachable), do: :transient
  def classify_error({:public_registry, _}), do: :permanent
  def classify_error({:registry_credentials, _, _}), do: :permanent
  def classify_error({:cli_unavailable, _}), do: :permanent

  def classify_error({kind, _ref, _status, output})
      when kind in [:push_failed, :pull_failed, :build_failed, :tag_failed] and is_binary(output) do
    classify_text(output)
  end

  def classify_error(other) when is_binary(other), do: classify_text(other)
  def classify_error(other), do: classify_text(inspect(other))

  defp classify_text(text) do
    down = String.downcase(text)

    cond do
      Enum.any?(@permanent_patterns, &String.contains?(down, &1)) -> :permanent
      Enum.any?(@transient_patterns, &String.contains?(down, &1)) -> :transient
      true -> :permanent
    end
  end

  @impl true
  def init(opts) do
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Settings.topic())

    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    if interval != :infinity, do: :timer.send_interval(interval, :tick)

    case Keyword.get(opts, :boot_delay_ms, @boot_delay_ms) do
      :infinity -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end

    {:ok,
     %{
       opts: opts,
       last_hash: nil,
       target_hash: nil,
       succeeded: MapSet.new(),
       retries: %{},
       failed: %{},
       retry_timer: nil,
       notices: %{}
     }}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {outcome, state} = check(state, :call)
    {:reply, outcome, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       last_hash: state.last_hash,
       retries: state.retries,
       failed: state.failed
     }, state}
  end

  @impl true
  def handle_info(:retry, state) do
    {:noreply, %{state | retry_timer: nil} |> check(:retry) |> elem(1)}
  end

  def handle_info(:tick, state), do: {:noreply, state |> check(:tick) |> elem(1)}

  def handle_info({:installation_settings_changed, :worker_cli_versions}, state),
    do: {:noreply, state |> check(:event) |> elem(1)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp check(%{opts: opts} = state, source) do
    with nil <- Settings.worker_cli_set_hold(),
         {:ok, set} <- CliSet.resolve(Keyword.get(opts, :cli_opts, [])) do
      state = maybe_reset_target(state, set.hash)
      run_for_set(state, set, source)
    else
      hold when is_binary(hold) -> {:held, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp maybe_reset_target(%{target_hash: hash} = state, hash), do: state

  defp maybe_reset_target(state, new_hash) do
    cancel_timer(state.retry_timer)

    %{
      state
      | target_hash: new_hash,
        succeeded: MapSet.new(),
        retries: %{},
        failed: %{},
        retry_timer: nil
    }
  end

  defp run_for_set(%{last_hash: hash} = state, %{hash: hash}, _source), do: {:unchanged, state}

  defp run_for_set(%{retry_timer: ref} = state, _set, :tick) when not is_nil(ref),
    do: {:unchanged, state}

  defp run_for_set(%{opts: opts} = state, set, _source) do
    ledger = Keyword.take(opts, [:ledger, :now])
    entries = PublishLedger.recent(Keyword.get(opts, :days, @days), ledger)
    pending = Enum.filter(entries, &should_attempt?(state, &1.key))

    if pending == [] and entries != [] do
      {:unchanged, state}
    else
      {results, state} = republish(pending, state)
      state = schedule_or_finish(state, set.hash)
      {{:republished, results}, state}
    end
  end

  defp should_attempt?(state, key) do
    cond do
      MapSet.member?(state.succeeded, key) -> false
      Map.has_key?(state.retries, key) -> true
      Map.has_key?(state.failed, key) -> false
      true -> true
    end
  end

  defp schedule_or_finish(state, hash) do
    cancel_timer(state.retry_timer)

    cond do
      map_size(state.retries) > 0 ->
        delay = state.retries |> Map.values() |> Enum.map(& &1.next_delay_ms) |> Enum.min()
        timer = if is_integer(delay), do: Process.send_after(self(), :retry, delay), else: nil
        %{state | retry_timer: timer}

      map_size(state.failed) > 0 ->
        %{state | retry_timer: nil}

      true ->
        %{state | retry_timer: nil, last_hash: hash}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp republish(entries, %{opts: opts} = state) do
    # `touch: false`: a republish updates the repo's digest and CLI facts in the
    # ledger without restarting its 14-day dispatch clock.
    ledger = Keyword.take(opts, [:ledger, :now])
    default_publish = &Publisher.ensure_ready(&1, Keyword.put(ledger, :touch, false))
    publish = Keyword.get(opts, :publish, default_publish)
    schedule = Keyword.get(opts, :retry_schedule_ms, @retry_schedule_ms)

    Enum.map_reduce(entries, state, fn %{key: key} = entry, acc ->
      prior = get_in(acc.retries, [key, :attempts]) || 0
      attempt = prior + 1
      prior_ref = get_in(acc.retries, [key, :ref])
      fallback_ref = prior_ref || resolve_ref(nil, entry, opts)

      if prior > 0 do
        Logger.warning(
          "CliSet.Watcher: retrying republish of #{inspect(key)} (#{fallback_ref}, attempt #{attempt})"
        )
      end

      raw = invoke_publish(entry, fallback_ref, publish, opts)
      result = normalize_result(raw)
      ref = resolve_ref(result, entry, opts, fallback_ref)
      acc = record_outcome(acc, entry, result, ref, attempt, schedule)
      {{key, result}, acc}
    end)
  end

  defp invoke_publish(%{ctx: ctx}, fallback_ref, publish, opts) do
    case check_reachability(ctx, opts) do
      :ok ->
        try do
          publish.(ctx)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {:error, reason} ->
        {:error, {:registry_unreachable, fallback_ref, reason}}
    end
  end

  defp check_reachability(ctx, opts) do
    cond do
      Keyword.has_key?(opts, :probe) ->
        run_probe(ctx, opts, Keyword.fetch!(opts, :probe))

      Keyword.has_key?(opts, :publish) ->
        :ok

      true ->
        run_probe(ctx, opts, &Registry.reachable/1)
    end
  end

  defp run_probe(ctx, opts, probe) do
    case Registry.resolve(Map.get(ctx, :workspace), Map.get(ctx, :repo), opts) do
      {:ok, cfg} -> probe.(cfg)
      :unset -> if Keyword.has_key?(opts, :probe), do: probe.(ctx), else: :ok
      {:error, _} -> :ok
    end
  end

  # The publish keeps running in the Publisher after the wait lapses, so a
  # timeout is progress to report, not a failure.
  defp normalize_result({:error, {:timeout, ms}}), do: {:still_publishing, div(ms, 1000)}
  defp normalize_result(other), do: other

  defp record_outcome(state, %{key: key}, {:still_publishing, secs}, ref, attempt, schedule) do
    delay = backoff_ms(attempt, schedule)

    Logger.warning(
      "CliSet.Watcher: republish of #{inspect(key)} (#{ref}) still publishing (#{secs}s); " <>
        "will check again next tick (retry in #{format_delay(delay)}, attempt #{attempt})"
    )

    retry_entry = %{
      attempts: attempt,
      last_error: {:timeout, secs * 1000},
      ref: ref,
      next_delay_ms: delay
    }

    %{state | retries: Map.put(state.retries, key, retry_entry)}
  end

  defp record_outcome(state, entry, {:error, reason}, ref, attempt, schedule) do
    case classify_error(reason) do
      :transient ->
        record_transient_failure(state, entry, reason, ref, attempt, schedule)

      :permanent ->
        record_permanent_failure(state, entry, reason, ref, attempt)
    end
  end

  defp record_outcome(state, %{key: key}, _ok_result, ref, attempt, _schedule) do
    prior = attempt - 1

    if prior > 0 do
      Logger.warning(
        "CliSet.Watcher: republish of #{inspect(key)} succeeded after #{prior} #{plural_retry(prior)}: #{ref}"
      )
    else
      Logger.info("CliSet.Watcher: republish of #{inspect(key)} succeeded: #{ref}")
    end

    state
    |> clear_notice(key)
    |> Map.put(:succeeded, MapSet.put(state.succeeded, key))
    |> Map.put(:retries, Map.delete(state.retries, key))
    |> Map.put(:failed, Map.delete(state.failed, key))
  end

  defp record_transient_failure(state, %{key: key} = entry, reason, ref, attempt, schedule) do
    delay = backoff_ms(attempt, schedule)

    Logger.warning(
      "CliSet.Watcher: republish of #{inspect(key)} (#{ref}) failed " <>
        "(transient, attempt #{attempt}, retrying in #{format_delay(delay)}): #{inspect(reason)}"
    )

    retry_entry = %{
      attempts: attempt,
      last_error: reason,
      ref: ref,
      next_delay_ms: delay
    }

    state = %{state | retries: Map.put(state.retries, key, retry_entry)}

    if attempt >= @persistent_transient_threshold do
      surface_persistent_failure(state, entry, reason, ref, attempt)
    else
      state
    end
  end

  defp record_permanent_failure(state, %{key: key} = entry, reason, ref, attempt) do
    Logger.error(
      "CliSet.Watcher: republish of #{inspect(key)} (#{ref}) failed permanently " <>
        "(will not retry): #{inspect(reason)}"
    )

    state
    |> Map.put(:retries, Map.delete(state.retries, key))
    |> surface_persistent_failure(entry, reason, ref, attempt)
  end

  defp surface_persistent_failure(state, %{key: key, ctx: ctx}, reason, ref, attempt) do
    failed_entry = %{
      reason: reason,
      ref: ref,
      attempts: attempt,
      at: DateTime.utc_now()
    }

    state
    |> Map.put(:failed, Map.put(state.failed, key, failed_entry))
    |> maybe_notify_coordinator(key, ctx, ref, reason)
  end

  defp maybe_notify_coordinator(state, key, ctx, ref, reason) do
    if Map.has_key?(state.notices, key) do
      state
    else
      repo = elem(key, 0) || Map.get(ctx, :repo) || "unknown"
      ws_id = resolve_workspace_id(ctx)
      subject = "CLI set image republish failed for #{repo}"

      body =
        "CliSet.Watcher could not republish the worker image #{ref} for #{inspect(key)}: " <>
          "#{format_reason(reason)}. Check registry credentials and permissions."

      case Message.send_mail(%{
             workspace_id: ws_id,
             to_ref: "coordinator",
             from_ref: "system",
             subject: subject,
             body: body
           }) do
        {:ok, msg} -> %{state | notices: Map.put(state.notices, key, msg.id)}
        _ -> state
      end
    end
  rescue
    _ -> state
  end

  defp clear_notice(state, key) do
    case Map.pop(state.notices, key) do
      {nil, _} ->
        state

      {msg_id, notices} ->
        _ = Message.mark_cleared(msg_id)
        %{state | notices: notices}
    end
  rescue
    _ -> state
  end

  defp resolve_workspace_id(ctx) do
    ws = Map.get(ctx, :workspace)

    cond do
      is_map(ws) and is_binary(Map.get(ws, :id)) ->
        Map.get(ws, :id)

      is_binary(Map.get(ctx, :workspace_id)) ->
        Map.get(ctx, :workspace_id)

      match?({:ok, id} when is_binary(id), Quota.default_workspace_id()) ->
        {:ok, id} = Quota.default_workspace_id()
        id

      true ->
        "default"
    end
  end

  @doc false
  @spec format_reason(term()) :: String.t()
  def format_reason({kind, ref, status, output})
      when kind in [:push_failed, :pull_failed, :build_failed, :tag_failed] do
    "#{kind} (#{ref}, exit #{status}): #{String.trim(to_string(output))}"
  end

  def format_reason({:registry_unreachable, ref, reason}),
    do: "registry unreachable for #{ref}: #{inspect(reason)}"

  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)

  defp resolve_ref(result, entry, opts, fallback \\ nil) do
    from_result(result) ||
      fallback ||
      from_entry(entry, opts)
  end

  defp from_result({:ok, %{ref: ref}}) when is_binary(ref), do: ref
  defp from_result({:ok, %{tag_ref: ref}}) when is_binary(ref), do: ref

  defp from_result({:error, {kind, ref, _status, _out}})
       when kind in [:push_failed, :pull_failed, :build_failed, :tag_failed] and is_binary(ref),
       do: ref

  defp from_result({:error, {:registry_unreachable, ref, _reason}}) when is_binary(ref), do: ref
  defp from_result({:error, {:no_digest, ref}}) when is_binary(ref), do: ref
  defp from_result({:error, {:public_registry, ref}}) when is_binary(ref), do: ref
  defp from_result(_), do: nil

  defp from_entry(entry, opts) do
    case Map.get(entry, :ref) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> from_entry_ctx(Map.get(entry, :ctx) || %{}, opts)
    end
  end

  defp from_entry_ctx(ctx, opts) do
    case Registry.resolve(Map.get(ctx, :workspace), Map.get(ctx, :repo), opts) do
      {:ok, cfg} ->
        base = Registry.repository(cfg, Pipeline.worker_repository(ctx))
        append_tag(base, get_in(ctx, [:plan, :hash]) || get_in(ctx, [:plan, :tag]))

      _ ->
        plan_tag_or_repo(ctx)
    end
  end

  defp append_tag(base, tag) when is_binary(tag) and tag != "", do: base <> ":" <> tag
  defp append_tag(base, _), do: base

  defp plan_tag_or_repo(ctx) do
    case get_in(ctx, [:plan, :tag]) do
      tag when is_binary(tag) -> tag
      _ -> Pipeline.worker_repository(ctx)
    end
  end

  defp format_delay(:infinity), do: "infinity"

  defp format_delay(ms) when is_integer(ms) and ms >= 3_600_000 and rem(ms, 3_600_000) == 0,
    do: "#{div(ms, 3_600_000)}h"

  defp format_delay(ms) when is_integer(ms) and ms >= 60_000 and rem(ms, 60_000) == 0,
    do: "#{div(ms, 60_000)}m"

  defp format_delay(ms) when is_integer(ms) and ms >= 1_000 and rem(ms, 1_000) == 0,
    do: "#{div(ms, 1_000)}s"

  defp format_delay(ms), do: "#{ms}ms"

  defp plural_retry(1), do: "retry"
  defp plural_retry(_), do: "retries"
end
