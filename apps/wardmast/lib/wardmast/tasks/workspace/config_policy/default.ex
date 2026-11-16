defmodule Wardmast.Tasks.Workspace.ConfigPolicy.Default do
  @moduledoc "Default `Wardmast.Tasks.Workspace.ConfigPolicy`: allows every config."

  @behaviour Wardmast.Tasks.Workspace.ConfigPolicy

  @impl true
  def check(_config, _context), do: :ok
end
