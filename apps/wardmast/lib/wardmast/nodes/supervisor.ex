defmodule Wardmast.Nodes.Supervisor do
  @moduledoc """
  The primary-side node session tree (`docs/design/remote-workers.md` §3, §4.2):
  `Wardmast.Nodes.Registry` (node id → session) and the dynamic supervisor that
  owns one `Wardmast.Nodes.Session` per connected node.

  Starting it also fixes the primary's `boot_epoch` for this BEAM
  (`Wardmast.Nodes.boot_epoch/0`). One failure domain: if the tree restarts, every
  session is gone, which is exactly what a new epoch tells the agents.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = Wardmast.Nodes.boot_epoch()

    Supervisor.init(
      [
        Wardmast.Nodes.Registry,
        Wardmast.Nodes.PlacementWatch,
        {DynamicSupervisor, strategy: :one_for_one, name: Wardmast.Nodes.SessionSupervisor}
      ],
      strategy: :one_for_all
    )
  end
end
