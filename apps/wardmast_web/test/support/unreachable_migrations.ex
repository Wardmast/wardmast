defmodule WardmastWeb.Test.UnreachableMigrations do
  @moduledoc false
  # Stands in for `Wardmast.Migrations` (`:migrations_module`) with the DB down.
  def count_pending, do: {:error, :unreachable}
end
