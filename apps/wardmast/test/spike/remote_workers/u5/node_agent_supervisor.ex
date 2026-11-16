# RW2 spike (bd-6tx1xv) U5 — NOT product code, never compiled by `mix`.
# A stand-in for the design's `Wardmast.NodeAgent.Supervisor`: the only thing the
# patched `Wardmast.Application` starts when `config :wardmast, role: :agent`.
defmodule Wardmast.NodeAgent.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: Supervisor.init([Wardmast.NodeAgent.Probe], strategy: :one_for_one)
end
