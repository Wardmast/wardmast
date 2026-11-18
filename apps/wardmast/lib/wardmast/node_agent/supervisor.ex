defmodule Wardmast.NodeAgent.Supervisor do
  @moduledoc """
  The only supervision tree an agent-role VM starts (`Wardmast.NodeAgent`):

      TaskSupervisor      readiness probes, the upgrade download
      Status              <node_home>/status.json (what `arbiter-node status` reads)
      Upgrader            one self-upgrade at a time
      RunRegistry         the run table (RW9: `Wardmast.NodeAgent.Runs`)
      RunSupervisor       one `Wardmast.NodeAgent.Run` per assigned run
      Monitor             senses temperature and memory pressure, derates (bd-6w7usy)
      Connection          the WebSocket to the primary

  `start_link/1` takes the `Wardmast.NodeAgent.Config.load/1` options. A config
  that cannot be loaded (no `ARB_NODE_URL`, no credential file, a world-readable
  one, a plain-`http` non-loopback URL) does **not** crash the VM: it records
  `unconfigured` and the reason in the status file and runs only the task
  supervisor, so `arbiter-node status` says what is wrong instead of systemd
  crash-looping the unit.

  With `ARB_AGENT_BACKEND=k8s` (a cluster controller, K14) the tree above is not
  started: `Wardmast.NodeAgent.K8s.Boot.children/1` is, and the boot starts the
  controller and its connection once it has a credential and an identity.
  """
  use Supervisor

  alias Wardmast.NodeAgent.Backend
  alias Wardmast.NodeAgent.Bridge
  alias Wardmast.NodeAgent.Config
  alias Wardmast.NodeAgent.Connection
  alias Wardmast.NodeAgent.K8s
  alias Wardmast.NodeAgent.Runs
  alias Wardmast.NodeAgent.Status
  alias Wardmast.NodeAgent.Upgrader

  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case Config.backend(opts) do
      # K14: a cluster controller learns its credential and identity at boot, from the
      # cluster and the primary, so its tree is started by `K8s.Boot` once they are known.
      {:ok, Backend.K8s} -> Supervisor.init(K8s.Boot.children(opts), strategy: :rest_for_one)
      _machine_or_unknown -> init_machine(opts)
    end
  end

  defp init_machine(opts) do
    task_supervisor = {Task.Supervisor, name: Wardmast.NodeAgent.TaskSupervisor}

    case Config.load(opts) do
      {:ok, config} ->
        # SI13: the one-time removal of the retired shelf and seed scratch, before any run.
        _ = Wardmast.NodeAgent.LegacyCleanup.run(config.node_home)
        backend = config.backend
        # The run table before the connection: `Connection` addresses runs.
        config = %{
          config
          | live_runs_fun: config.live_runs_fun || (&backend.inventory/0),
            run_opts: bridge_run_opts(config.run_opts)
        }

        Supervisor.init(
          [
            task_supervisor,
            {Status, path: config.status_path},
            {Upgrader, config: config}
          ] ++
            Runs.child_specs() ++
            [{Wardmast.NodeAgent.ImageGC, config: config}, prefetch_spec(config)] ++
            [
              {Bridge, node_home: config.node_home},
              monitor_spec(config),
              {Connection, config: config}
            ],
          strategy: :one_for_one
        )

      {:error, {:unknown_backend, name}} ->
        raise ArgumentError,
              "unknown ARB_AGENT_BACKEND #{inspect(name)} (expected one of: " <>
                "#{Enum.join(Backend.names(), ", ")})"

      {:error, reason} ->
        Logger.error("node agent is not configured: #{inspect(reason)}")
        record_unconfigured(opts, reason)
        Supervisor.init([task_supervisor], strategy: :one_for_one)
    end
  end

  # The per-run bridge listeners (RW10): `Run` asks for them when it prepares and
  # gives them back when it ends. A test's own `:bridges_fun` wins.
  defp bridge_run_opts(run_opts) do
    run_opts
    |> Keyword.put_new(:bridges_fun, &Bridge.listen/2)
    |> Keyword.put_new(:bridges_release_fun, &Bridge.release/1)
  end

  # SI7: the `image.prefetch` queue, one background pull at a time.
  defp prefetch_spec(config) do
    pull_opts =
      Keyword.take(config.run_opts, [
        :podman,
        :runner,
        :runtime_dir,
        :require_tmpfs,
        :mountinfo,
        :pull_timeout_ms
      ])

    {Wardmast.NodeAgent.ImagePrefetch, pull_opts: pull_opts}
  end

  # bd-6w7usy: the machine senses its own temperature and memory pressure and derates the slots
  # it offers; each heartbeat reports the result (`Protocol.heartbeat/2`). Before `Connection`.
  # Its cap is the node's own (suggestion, bounded by the owner's ceiling); the primary applies
  # the derate level to whatever cap the operator has set.
  defp monitor_spec(config) do
    {Wardmast.Machine.Monitor,
     name: config.monitor,
     config_fun: fn -> config.derate end,
     cap_fun: fn -> own_cap(config) end,
     live_fun: fn -> length(Wardmast.NodeAgent.Protocol.live_runs(config)) end}
  end

  defp own_cap(config) do
    suggestion = Wardmast.NodeAgent.Protocol.capacity_facts()["suggestion"]
    if config.max_workers, do: min(suggestion, config.max_workers), else: suggestion
  end

  defp record_unconfigured(opts, reason) do
    path = Path.join(Config.node_home(opts), "status.json")

    Status.write(path, %{
      "state" => "unconfigured",
      "error" => inspect(reason),
      "pid" => System.pid(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
