defmodule WardmastCli.ConfigParityTest do
  use ExUnit.Case, async: true

  # bd-2n4k1a: this app must see the same compile-time config as the other
  # umbrella apps, else Mix recompiles ash and friends whenever a run
  # alternates between apps (the pre-push `tests` step timed out on it).
  test "shares the umbrella root's :ash compile config" do
    assert Application.get_env(:ash, :default_page_type) == :keyset
    assert Application.get_env(:ash, :bulk_actions_default_to_errors?) == true
  end
end
