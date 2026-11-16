defmodule Wardmast.Extension.Value do
  @moduledoc """
  Behaviour for the module a contribution to a *value seam* points at.

  The `:issue_type` and `:session_kind` seams register no code, only a name a
  persisted attribute may hold (`Wardmast.Extensions.RegisteredAtom`). The module
  exists so the registry's callback check applies uniformly; core points every
  key at `Wardmast.Extensions.Core.Values`.
  """

  @doc "One line saying what the value means."
  @callback description() :: String.t()
end
