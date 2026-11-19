defmodule Wardmast.Worker.GlabIsolationTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.GlabIsolation

  test "GLAB_CONFIG_DIR is an existing empty dir outside the operator's home" do
    assert [{"GLAB_CONFIG_DIR", dir}] = GlabIsolation.env()
    assert File.dir?(dir)
    refute String.starts_with?(dir, System.user_home!())
  end
end
