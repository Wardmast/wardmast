defmodule Wardmast.Workers.StuckStartReaper do
  @moduledoc """
  Reaps runs left in `starting` with no agent past a timeout (GitHub #1657).

  A worker is registered `:starting` before its agent session is built. When the
  start fails after that point, nothing used to end it: the worker stayed in the
  registry and its `Wardmast.Workers.Run` row stayed `starting` (`agent_live:
  false`, step `idle`) for as long as the server ran — 24 hours and more for a
  ReviewGate `<ticket>#review#impl<N>` run. `Wardmast.Workers.Current` reads the
  live registry, so `worker_list`, `worker_show` and `arb prime` reported it as the
  ticket's current run while the ticket moved on past it.

  The gate now discards a start that failed (`Wardmast.Worker.ReviewGate`); this
  is the backstop for every other path, and for rows an earlier build left behind:

    * a **live worker** in `:starting` that never opened an agent session (a worker
      holding for a resume backoff or quota wait has opened one and is left alone),
      started more than
      `timeout_ms/0` ago, is ended `interrupted` with the typed `:spawn_failed`
      stop reason and stopped, so its id is free again;
    * a **`starting` run row** past the timeout that no live worker owns is ended
      `interrupted` (`failure_reason: "stuck in starting …"`).

  The timeout (default 45 minutes) is longer than a remote placement's own deadline
  (`Wardmast.Nodes.PlacementWatch`, 30 minutes), so a placement that is merely slow
  is never reaped; it is not a limit on how long an agent may run.

  ## Configuration

  `config :wardmast, :stuck_start_reaper`: `:enabled` (default `true`; `false` in
  test, where tests drive `sweep/1`), `:interval_ms` (default one minute) and
  `:timeout_ms` (default 45 minutes).
  """

  use GenServer

  alias Wardmast.Worker
  alias Wardmast.Worker.StopReason
  alias Wardmast.Workers.Run

  require Ash.Query
  require Logger

  @default_interval_ms :timer.minutes(1)
  @default_timeout_ms :timer.minutes(45)

  @type report :: %{workers: [String.t()], runs: [String.t()]}

  # ---- process -------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    if Keyword.get(opts, :enabled, config(:enabled, true)), do: schedule(self(), interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = sweep()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, interval_ms), do: Process.send_after(pid, :tick, interval_ms)

  defp config(key, default) do
    :wardmast |> Application.get_env(:stuck_start_reaper, []) |> Keyword.get(key, default)
  end

  @doc "How long a run may sit in `starting` with no agent before it is reaped."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: config(:timeout_ms, @default_timeout_ms)

  # ---- the sweep -----------------------------------------------------------

  @doc """
  One sweep. Returns the ids it reaped: `%{workers: [worker task id], runs: [row
  task id]}`. Options: `:now` (a `DateTime`, for tests) and `:timeout_ms`.
  Never raises.
  """
  @spec sweep(keyword()) :: report()
  def sweep(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timeout = Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)
    cutoff = DateTime.add(now, -timeout, :millisecond)

    live = Worker.list_children()
    workers = live |> Enum.filter(&stuck_worker?(&1, cutoff)) |> Enum.flat_map(&reap_worker/1)

    # A live worker owns its run row even when its snapshot probe timed out (the
    # degraded entry carries no `run_id`), so ownership is by run id, task id or
    # registry key.
    owned = live |> Enum.flat_map(&[&1[:run_id], &1[:task_id], &1[:registry_key]]) |> MapSet.new()

    %{workers: workers, runs: reap_rows(cutoff, owned)}
  rescue
    e ->
      Logger.warning("StuckStartReaper: sweep failed: #{Exception.message(e)}")
      %{workers: [], runs: []}
  catch
    :exit, reason ->
      Logger.warning("StuckStartReaper: sweep exited: #{inspect(reason)}")
      %{workers: [], runs: []}
  end

  # Only a start that never opened an agent session is stuck. A worker holding at
  # `:starting` for a resume backoff or a quota wait has `agent_live: false` too,
  # but its session is on record (`session_opened`) and a respawn is scheduled.
  defp stuck_worker?(
         %{
           state: :starting,
           agent_live: false,
           session_opened: false,
           started_at: %DateTime{} = at
         },
         cutoff
       ),
       do: DateTime.compare(at, cutoff) == :lt

  defp stuck_worker?(_snapshot, _cutoff), do: false

  defp reap_worker(%{task_id: task_id}) do
    case Worker.whereis(task_id) do
      nil ->
        []

      pid ->
        Logger.warning(
          "StuckStartReaper: worker #{task_id} has been `starting` with no agent past " <>
            "#{div(timeout_ms(), 60_000)} min; ending its run and stopping it"
        )

        _ = Worker.interrupt(pid, StopReason.spawn_failed(:stuck_starting))
        _ = Worker.stop(pid, :normal, 5_000)
        [task_id]
    end
  catch
    :exit, _ -> []
  end

  defp reap_rows(cutoff, owned) do
    Run
    |> Ash.Query.filter(state == :starting and started_at < ^cutoff)
    |> Ash.read!()
    |> Enum.reject(&(MapSet.member?(owned, &1.id) or MapSet.member?(owned, &1.task_id)))
    |> Enum.flat_map(&end_row/1)
  end

  defp end_row(%Run{} = run) do
    attrs = %{
      state: :finished,
      outcome: :interrupted,
      completed_at: DateTime.utc_now(),
      failure_reason: "stuck in starting: no agent ever started and no worker owns this run"
    }

    case Ash.update(run, attrs, action: :update) do
      {:ok, _} ->
        [run.task_id]

      {:error, reason} ->
        Logger.warning(
          "StuckStartReaper: could not end run #{run.id} (#{run.task_id}): #{inspect(reason)}"
        )

        []
    end
  end
end
