defmodule Wardmast.VersionReleaseRepoTest do
  # async: false — mutates WARDMAST_RELEASE_REPO.
  use ExUnit.Case, async: false

  setup do
    previous = Wardmast.Env.get("WARDMAST_RELEASE_REPO")

    on_exit(fn ->
      if previous,
        do: System.put_env("WARDMAST_RELEASE_REPO", previous),
        else: System.delete_env("WARDMAST_RELEASE_REPO")
    end)

    System.delete_env("WARDMAST_RELEASE_REPO")
    :ok
  end

  test "WARDMAST_RELEASE_REPO overrides whatever the build stamped" do
    System.put_env("WARDMAST_RELEASE_REPO", "acme/arbiter")
    assert Wardmast.Version.release_repo() == "acme/arbiter"
  end

  test "an empty WARDMAST_RELEASE_REPO is unset" do
    System.put_env("WARDMAST_RELEASE_REPO", "")
    assert Wardmast.Version.release_repo() == Wardmast.Version.build_release_repo()
  end
end
