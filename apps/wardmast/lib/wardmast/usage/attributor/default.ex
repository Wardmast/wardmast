defmodule Wardmast.Usage.Attributor.Default do
  @moduledoc "Core attributor: records the dimensions the ledger row already carries."

  @behaviour Wardmast.Usage.Attributor

  @impl true
  def attribute(attrs) do
    for key <- Wardmast.Usage.Attributor.core_keys(),
        value = Map.get(attrs, key),
        into: %{} do
      {Atom.to_string(key), to_string(value)}
    end
  end
end
