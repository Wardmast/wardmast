defmodule WardmastCliTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    Code.ensure_loaded!(WardmastCli)
    assert is_atom(WardmastCli)
  end
end
