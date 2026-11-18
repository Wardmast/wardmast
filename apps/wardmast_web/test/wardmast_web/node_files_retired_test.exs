defmodule WardmastWeb.NodeFilesRetiredTest do
  @moduledoc "SI13: `/nodes/files/:sha` (the CLI shelf and the tarball alias) is gone."
  use ExUnit.Case, async: true

  test "the route and its action are gone" do
    paths = for r <- WardmastWeb.Router.__routes__(), do: r.path
    refute Enum.any?(paths, &String.starts_with?(&1, "/nodes/files"))
    refute function_exported?(WardmastWeb.NodeController, :file, 2)
  end
end
