defmodule Wardmast.Worker.Egress.Supervisor do
  @moduledoc """
  The long-lived parts of `Wardmast.Worker.Egress`: the grant cache, the
  registry that maps a run id to its proxy processes, and the dynamic
  supervisor those per-run proxies start under. Idle until something calls
  `Wardmast.Worker.Egress.start_run/2`: `Wardmast.Worker.Egress.JailRun` does,
  once per jailed agy run (G6, bd-cfktou).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      # First, so a crash (which loses every recorded bridge identity) restarts
      # the runs after it too instead of leaving them without one.
      Wardmast.Worker.Egress.BridgeIdentity,
      Wardmast.Worker.Egress.GrantCache,
      {Registry, keys: :unique, name: Wardmast.Worker.Egress.Registry},
      {DynamicSupervisor, name: Wardmast.Worker.Egress.RunSupervisors, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
