defmodule Wardmast.Machine.Local do
  @moduledoc """
  The primary's own self-derate (bd-6w7usy): an `Wardmast.Machine.Monitor`
  sampling this machine for the slots the primary offers itself
  (`Wardmast.Nodes.LocalCapacity`). Thresholds come from the installation
  setting `machine.derate` (`Wardmast.Settings.machine_derate/0`) and are re-read
  every sample, so a change applies within ~10 s with no restart. On by default.

  A hard derate (entering or leaving) raises or clears the `machine_derate`
  system alert (`Wardmast.Machine.Alerting`).

  `config :wardmast, :machine_monitor, false` keeps it from starting (the test
  suite, so the host running the tests cannot derate them).
  """

  alias Wardmast.Machine.Alerting
  alias Wardmast.Machine.Derate.Config
  alias Wardmast.Machine.Monitor
  alias Wardmast.Nodes
  alias Wardmast.Nodes.LocalCapacity
  alias Wardmast.Settings

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init(child_specs(), strategy: :one_for_one)

  @doc false
  def child_specs do
    if Application.get_env(:wardmast, :machine_monitor, true) do
      [
        {Monitor,
         name: Monitor,
         config_fun: &config/0,
         cap_fun: fn -> LocalCapacity.cap().cap end,
         live_fun: fn -> length(LocalCapacity.holders()) end,
         on_transition: &Alerting.transition(Map.put(&1, :machine, Nodes.local_name()))}
      ]
    else
      []
    end
  end

  @doc "The thresholds in force for the primary."
  @spec config() :: Config.t()
  def config, do: Config.build(Settings.machine_derate())
end
