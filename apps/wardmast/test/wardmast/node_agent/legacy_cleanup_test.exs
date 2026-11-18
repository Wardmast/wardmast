defmodule Wardmast.NodeAgent.LegacyCleanupTest do
  use ExUnit.Case, async: true

  alias Wardmast.NodeAgent.LegacyCleanup

  @moduletag :tmp_dir

  test "removes the shelf and the seed scratch once, and nothing else", %{tmp_dir: home} do
    for d <- ~w(files deps-seed deps-cache runs), do: File.mkdir_p!(Path.join([home, d, "x"]))

    assert :ok = LegacyCleanup.run(home)
    refute File.exists?(Path.join(home, "files"))
    refute File.exists?(Path.join(home, "deps-seed"))
    assert File.dir?(Path.join(home, "deps-cache"))
    assert File.dir?(Path.join(home, "runs"))

    # a later run of the agent leaves what a seed job has since put there alone
    File.mkdir_p!(Path.join(home, "deps-seed"))
    assert :skipped = LegacyCleanup.run(home)
    assert File.dir?(Path.join(home, "deps-seed"))
  end

  test "a missing or blank node home is skipped" do
    assert :skipped = LegacyCleanup.run(nil)
    assert :skipped = LegacyCleanup.run("")
    assert :skipped = LegacyCleanup.run("/nonexistent/si13-home")
  end
end
