defmodule Wardmast.Extensions.Core.Values do
  @moduledoc """
  The module core's `:issue_type` and `:session_kind` keys point at; see
  `Wardmast.Extension.Value`.
  """

  @behaviour Wardmast.Extension.Value

  @impl true
  def description, do: "core value"
end
