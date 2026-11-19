defmodule Wardmast.Worker.MemoryWatchdog do
  @moduledoc """
  The optional per-worker memory cap on macOS: a polling RSS watchdog over the
  agent's process group (bd-d627b8, MAC P3-3; design decision D3).

  Linux caps a worker with a transient systemd scope (`Wardmast.Worker.MemoryScope`,
  `docs/worker-memory-cap.md`); the kernel enforces it. macOS has no cgroups, so
  nothing enforces anything and the cap here is **polling-based and best-effort**:

    * every `interval_ms` (5 s) one `ps -axo pgid=,rss=` is read and the RSS of
      every process whose process group is the agent's (`Wardmast.Worker.ProcessGroup`)
      is summed. The group is the agent plus everything it started that did not
      leave on purpose, so a runaway `mix test` BEAM counts;
    * the first sample above the cap tells the owning `Wardmast.Worker`
      (`{:memory_watchdog_exceeded, pgid, %{max:, peak:, source: :watchdog}}`) and
      then SIGKILLs the group. The Worker records the run as stopped with
      `:memory_cap_exceeded` (`Wardmast.Worker.StopReason.memory_cap_exceeded/2`),
      exactly as for an OOM-killed Linux scope. The notice goes out before the kill
      so it is in the Worker's mailbox before the port reports the exit.

  ## Limits

  A process can grow far past the cap, and fork bombs can outrun a 5 s poll, before
  it is seen. RSS double-counts shared pages, and a process that left the group
  (its own `setsid`) is not counted. A failed `ps` skips that sample.

  ## Configuration

  Opt-in, macOS only. The same setting as the Linux cap:
  `WARDMAST_WORKER_MEMORY_MAX` (`12G`, `512M`, or a percentage of physical RAM such
  as `40%`) or `config :wardmast, :worker_memory_max`. Unset, `off`, `0`, `none`,
  `infinity` or an unparseable value means no watchdog (unlike Linux there is no
  default cap, since this one is approximate). Linux hosts never start it.

  ## Lifecycle

  One unlinked process per spawned group, started by `maybe_start/2` (its pid is
  carried on the group map as `:watchdog`), stopped by `stop/1` when the group is
  reaped, and exiting by itself if its owner dies or after it has killed the group.
  """

  use GenServer

  require Logger

  alias Wardmast.Worker.ProcessGroup

  @default_interval_ms 5_000
  @kib 1024
  @units %{"" => 1, "K" => 1024, "M" => 1_048_576, "G" => 1_073_741_824, "T" => 1_099_511_627_776}
  @disabled ~w(off none 0 infinity false disabled)
  @size_re ~r/\A(\d+(?:\.\d+)?)([KMGT]?)\z/
  @percent_re ~r/\A(\d{1,3})%\z/

  @type cap :: %{bytes: pos_integer(), label: String.t()}

  # ---- configuration -----------------------------------------------------------

  @doc """
  The configured cap, `{:ok, %{bytes:, label:}}`, or `:disabled`. Environment beats
  application config; unset, invalid and non-macOS are all `:disabled`.

  Options (test seams): `:os` (`:darwin` | other), `:env`, `:config`,
  `:total_memory` (bytes, or `nil` when unknown).
  """
  @spec cap(keyword()) :: {:ok, cap()} | :disabled
  def cap(opts \\ []) do
    with :darwin <- Keyword.get_lazy(opts, :os, &host_os/0),
         raw when is_binary(raw) <- raw_setting(opts),
         {:ok, cap} <- parse_cap(raw, opts) do
      {:ok, cap}
    else
      _ -> :disabled
    end
  end

  defp host_os do
    case :os.type() do
      {:unix, os} -> os
      {_family, os} -> os
    end
  end

  defp raw_setting(opts) do
    env = Keyword.get_lazy(opts, :env, fn -> Wardmast.Env.get("WARDMAST_WORKER_MEMORY_MAX") end)

    config =
      Keyword.get_lazy(opts, :config, fn -> Application.get_env(:wardmast, :worker_memory_max) end)

    presence(env) || presence(config)
  end

  defp presence(nil), do: nil

  defp presence(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_cap(raw, opts) do
    value = String.upcase(raw)

    cond do
      String.downcase(raw) in @disabled ->
        :error

      match = Regex.run(@percent_re, value) ->
        percent_cap(match, value, opts)

      match = Regex.run(@size_re, value) ->
        size_cap(match, value)

      true ->
        :error
    end
  end

  defp size_cap([_, number, unit], label) do
    {n, _} = Float.parse(number)

    case round(n * Map.fetch!(@units, unit)) do
      bytes when bytes > 0 -> {:ok, %{bytes: bytes, label: label}}
      _ -> :error
    end
  end

  defp percent_cap([_, percent], label, opts) do
    total = Keyword.get_lazy(opts, :total_memory, &total_memory/0)
    pct = String.to_integer(percent)

    if is_integer(total) and total > 0 and pct in 1..100,
      do: {:ok, %{bytes: div(total * pct, 100), label: label}},
      else: :error
  end

  # Physical RAM in bytes; only asked for when the cap is a percentage.
  defp total_memory do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {bytes, ""} -> bytes
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---- sampling ----------------------------------------------------------------

  @doc """
  Sum the RSS of the rows of `ps -axo pgid=,rss=` output that belong to `pgid`, in
  bytes (`ps` reports KiB). Lines that are not two integers are ignored.
  """
  @spec parse_rss(String.t(), integer()) :: {:ok, non_neg_integer()}
  def parse_rss(out, pgid) when is_binary(out) and is_integer(pgid) do
    kib =
      out
      |> String.split("\n", trim: true)
      |> Enum.reduce(0, fn line, acc ->
        with [g, r] <- String.split(line, ~r/\s+/, trim: true),
             {^pgid, ""} <- Integer.parse(g),
             {rss, ""} <- Integer.parse(r) do
          acc + rss
        else
          _ -> acc
        end
      end)

    {:ok, kib * @kib}
  end

  @doc "The default sampler: `ps` summed over the group. `:error` when `ps` fails."
  @spec sample(integer()) :: {:ok, non_neg_integer()} | :error
  def sample(pgid) when is_integer(pgid) do
    case System.cmd("ps", ["-axo", "pgid=,rss="], stderr_to_stdout: true) do
      {out, 0} -> parse_rss(out, pgid)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ---- the poll step (pure apart from the injected sampler / killer) -------------

  @doc false
  @spec new_state(keyword()) :: map()
  def new_state(opts) do
    %{
      owner: Keyword.fetch!(opts, :owner),
      group: Keyword.fetch!(opts, :group),
      cap: Keyword.fetch!(opts, :cap),
      sampler: Keyword.get(opts, :sampler, &sample/1),
      killer: Keyword.get(opts, :killer, &ProcessGroup.kill/1),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      peak: 0
    }
  end

  @doc """
  One sample. `{:ok, state}` while under the cap (the peak is tracked) or when the
  sample failed; `{:exceeded, state}` after telling the owner and killing the group.
  """
  @spec poll(map()) :: {:ok, map()} | {:exceeded, map()}
  def poll(%{group: %{pgid: pgid}} = state) do
    case state.sampler.(pgid) do
      {:ok, rss} ->
        state = %{state | peak: max(state.peak, rss)}

        if rss > state.cap.bytes do
          exceeded(state, pgid, rss)
        else
          {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  defp exceeded(state, pgid, rss) do
    Logger.warning(
      "MemoryWatchdog: process group #{pgid} RSS #{rss} bytes exceeds the per-worker cap " <>
        "(#{state.cap.label}); killing it"
    )

    info = %{max: state.cap.label, peak: state.peak, source: :watchdog}
    send(state.owner, {:memory_watchdog_exceeded, pgid, info})

    case state.killer.(state.group) do
      result when result in [:ok, :gone] ->
        :ok

      other ->
        Logger.warning("MemoryWatchdog: could not kill process group #{pgid}: #{inspect(other)}")
    end

    {:exceeded, state}
  end

  # ---- process -----------------------------------------------------------------

  @doc """
  Start a watchdog (unlinked; it monitors `:owner` and exits with it). Options:
  `:owner`, `:group`, `:cap` (a `t:cap/0`), and the test seams `:interval_ms`,
  `:sampler` (`fn pgid -> {:ok, bytes} | :error end`), `:killer` (`fn group -> :ok`).
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc """
  Start a watchdog for `group` when the cap is enabled and the group can be
  group-killed, recording its pid on the group as `:watchdog`. Otherwise `group`
  is returned untouched. `:cap` overrides `cap/0` (test seam); the other options
  are `start/1`'s. `config :wardmast, :memory_watchdog, [...]` supplies defaults for all of
  them (tests).
  """
  @spec maybe_start(map() | nil, keyword()) :: map() | nil
  def maybe_start(group, opts \\ [])

  def maybe_start(%{pgid: pgid} = group, opts) when is_integer(pgid) do
    opts = Keyword.merge(Application.get_env(:wardmast, :memory_watchdog, []), opts)

    case Keyword.get_lazy(opts, :cap, &cap/0) do
      {:ok, cap} ->
        opts = opts |> Keyword.put(:group, group) |> Keyword.put(:cap, cap)

        case start(opts) do
          {:ok, pid} -> Map.put(group, :watchdog, pid)
          _ -> group
        end

      _ ->
        group
    end
  end

  def maybe_start(group, _opts), do: group

  @doc "Stop a watchdog without killing anything. A nil or dead pid is a no-op."
  @spec stop(pid() | nil) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def stop(_), do: :ok

  @impl GenServer
  def init(opts) do
    state = new_state(opts)
    Process.monitor(state.owner)
    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    case poll(state) do
      {:ok, state} ->
        schedule(state)
        {:noreply, state}

      {:exceeded, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(%{interval_ms: ms}), do: Process.send_after(self(), :poll, ms)
end
