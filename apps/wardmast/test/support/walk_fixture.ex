defmodule Wardmast.Board.WalkFixture do
  @moduledoc """
  Test fixture for Autopilot suites that feed a hand-built board through the
  `:snapshot` seam. Since DC12 the scheduler walk is the only admission, so a
  board that promotes a card has to carry the walk that places it. `with_walk/1`
  mirrors a board's `promote` and `ready` entries as a trivial walk: the
  promoted card is the one placement, on an unmetered pool of the local node.
  """

  @pool {:unmetered, :claude}

  @doc "`board` plus a `:walk` that places exactly its `promote`d card, if any."
  @spec with_walk(map()) :: map()
  def with_walk(%{} = board) do
    promote = Map.get(board, :promote)
    ready = Map.get(board, :ready, [])

    placements = if promote, do: [%{id: promote, pool: @pool, node: "local"}], else: []

    entries =
      Enum.map(ready, fn entry ->
        Map.merge(entry, %{wait_cause: nil, pair: %{pool: @pool, node: "local"}})
      end)

    Map.put(board, :walk, %{
      promote: promote,
      placements: placements,
      entries: entries,
      pools: %{},
      nodes: %{}
    })
  end
end
