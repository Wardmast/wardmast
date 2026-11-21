defmodule Wardmast.Screenshots.Capture.Services.Reaper do
  @moduledoc """
  Removes a capture boot's service containers (`Wardmast.Screenshots.Capture.Services.Podman`,
  bd-3glf2a) on the exit paths the boot's own `after` cannot cover:

    * **the owner dies**, however (a capture task killed from outside, `:kill` included): it is
      monitored, and what it left is removed on `:DOWN`;
    * **the server shuts down**: this process traps exits, so `terminate/2` removes everything
      still tracked. It is started before `Wardmast.TaskSupervisor`, so it is stopped after the
      capture tasks are;
    * **the server died hard** (`kill -9`, a power cut): at boot it removes every container
      labelled `arbiter.capture-service=<os pid>` whose server is no longer alive
      (`Podman.reap_orphans/1`), never one of a live server.

  What it tracks is `{:container, name, podman_opts}` (removed by exact name, `podman rm --force`)
  and `{:dir, path}` (the boot's socket directory). `Services.Podman` tracks a container *before*
  it runs it and untracks it once its own `stop/1` removed it.

  The boot sweep is off under `config :wardmast, :capture_services_reaper, enabled: false`
  (test), and with `enabled: false` in the start options.
  """

  use GenServer, shutdown: 30_000

  # Terminate removes every tracked container concurrently, so the whole pass takes about one
  # removal, not one per container. The per-container cap sits under the shutdown budget.
  @remove_timeout_ms 20_000

  alias Wardmast.Screenshots.Capture.Services.Podman

  require Logger

  @type item :: {:container, String.t(), keyword()} | {:dir, String.t()}

  @doc "Start the reaper. Options: `:name` (default this module; `nil` for none), `:enabled`."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Clean `item` up when `owner` exits. Best effort: `:ok` when no reaper is running."
  @spec track(GenServer.server(), pid(), item()) :: :ok
  def track(server, owner, item) when is_pid(owner), do: call(server, {:track, owner, item})

  @doc "Forget `item` (its owner removed it)."
  @spec untrack(GenServer.server(), pid(), item()) :: :ok
  def untrack(server, owner, item) when is_pid(owner), do: call(server, {:untrack, owner, item})

  defp call(server, msg) do
    GenServer.call(server, msg, 15_000)
  catch
    :exit, reason ->
      Logger.warning(
        "Capture.Services.Reaper: #{inspect(elem(msg, 0))} failed: #{inspect(reason)}"
      )

      :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cfg = Application.get_env(:wardmast, :capture_services_reaper, [])
    state = %{owners: %{}, sweep_opts: Keyword.take(opts, [:runner, :podman, :alive?])}

    if Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)),
      do: {:ok, state, {:continue, :sweep}},
      else: {:ok, state}
  end

  # The sweep (`podman ps`, then a `podman rm` of up to 30 s per orphan) runs in its own process:
  # in this one it would block `track/3` past its call timeout, which is swallowed, and a
  # capture starting meanwhile could run a container the reaper never heard of. It only removes
  # containers of dead servers, so it needs nothing from the state.
  @impl true
  def handle_continue(:sweep, %{sweep_opts: opts} = state) do
    {:ok, _pid} = Task.start(fn -> sweep(opts) end)
    {:noreply, state}
  end

  defp sweep(opts) do
    case Podman.reap_orphans(opts) do
      [] ->
        :ok

      removed ->
        Logger.info("Capture.Services.Reaper: removed orphaned #{Enum.join(removed, ", ")}")
    end
  rescue
    e -> Logger.warning("Capture.Services.Reaper: sweep failed: #{Exception.message(e)}")
  end

  @impl true
  def handle_call({:track, owner, item}, _from, %{owners: owners} = state) do
    owners =
      case Map.fetch(owners, owner) do
        {:ok, %{items: items} = entry} -> Map.put(owners, owner, %{entry | items: [item | items]})
        :error -> Map.put(owners, owner, %{ref: Process.monitor(owner), items: [item]})
      end

    {:reply, :ok, %{state | owners: owners}}
  end

  def handle_call({:untrack, owner, item}, _from, %{owners: owners} = state) do
    owners =
      case Map.fetch(owners, owner) do
        {:ok, %{ref: ref, items: items}} ->
          case List.delete(items, item) do
            [] ->
              Process.demonitor(ref, [:flush])
              Map.delete(owners, owner)

            rest ->
              Map.put(owners, owner, %{ref: ref, items: rest})
          end

        :error ->
          owners
      end

    {:reply, :ok, %{state | owners: owners}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owners: owners} = state) do
    {entry, owners} = Map.pop(owners, owner)
    if entry, do: clean(entry.items)
    {:noreply, %{state | owners: owners}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{owners: owners}) do
    owners |> Map.values() |> Enum.flat_map(& &1.items) |> clean()
    :ok
  end

  # Containers first (a dir holds only their sockets), concurrently; a raise or a timeout on one
  # must not lose the rest.
  defp clean(items) do
    {containers, dirs} = Enum.split_with(items, &match?({:container, _, _}, &1))

    containers
    |> Task.async_stream(&safe_clean_one/1,
      max_concurrency: max(length(containers), 1),
      timeout: @remove_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()

    Enum.each(dirs, &safe_clean_one/1)
  end

  defp safe_clean_one(item) do
    clean_one(item)
  rescue
    e -> Logger.warning("Capture.Services.Reaper: #{inspect(item)}: #{Exception.message(e)}")
  end

  defp clean_one({:container, name, opts}) do
    case Podman.remove(name, opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Capture.Services.Reaper: #{name}: #{inspect(reason)}")
    end
  end

  defp clean_one({:dir, path}) do
    _ = File.rm_rf(path)
    :ok
  end
end
