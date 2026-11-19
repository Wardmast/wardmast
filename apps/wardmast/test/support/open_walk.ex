defmodule Wardmast.Board.OpenWalk do
  @moduledoc """
  Test support: a scheduler walk (`Wardmast.Board.Scheduler`'s `:walk`) with one
  pool and one machine, both `slots` wide, that every card can run on. It stands
  in for a board with plain capacity, so a test about a card's own holds, the
  queue's order or the board's columns need not build capacity sets.

  `used` seats and slots are already taken (`slots - used` are free). With
  `slots: 0` nothing has room, and every free card waits for capacity.
  """

  alias Wardmast.Tasks.SlotGate

  @pool {"acct-test", "claude"}

  @doc """
  `input` (a `Wardmast.Board.Snapshot.derive/1` input) carrying an open walk
  sized by its `:slots_total`, with the tickets In progress as the seats in
  use. An input that already names a `:walk` is left alone.
  """
  @spec put(map()) :: map()
  def put(%{walk: _} = input), do: input

  def put(input) do
    used =
      input
      |> Map.get(:issues, [])
      |> SlotGate.slots_used(idle_ids: Map.get(input, :idle_ids, []))

    Map.put(input, :walk, walk(slots: Map.get(input, :slots_total, 0), used: used))
  end

  @doc "The open walk; `opts`: `:slots` (default 1) and `:used` (default 0)."
  @spec walk(keyword()) :: map()
  def walk(opts \\ []) do
    slots = Keyword.get(opts, :slots, 1)
    used = Keyword.get(opts, :used, 0)

    %{
      pools: %{@pool => %{budget: slots, seats: used, label: "claude:default"}},
      nodes: %{"local" => %{cap: slots, used: used, label: "local"}},
      candidates: fn _card -> [%{pool: @pool, nodes: ["local"]}] end
    }
  end
end
