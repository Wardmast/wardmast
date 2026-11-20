defmodule Wardmast.Worker.PrimarySyncTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.PrimarySync

  setup do
    unique = "ps009-#{:erlang.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), unique)
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])

    seed = Path.join(tmp, "seed")
    File.mkdir_p!(seed)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", seed])
    {_, 0} = System.cmd("git", ["-C", seed, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", seed, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", seed, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(seed, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", seed, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", seed, "commit", "-q", "-m", "initial"])
    {_, 0} = System.cmd("git", ["-C", seed, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", seed, "push", "-q", "origin", "main"])

    # Primary checkout: a clone that stays "behind" until a test advances the
    # remote and calls PrimarySync — mirrors a human's long-lived local repo.
    primary = Path.join(tmp, "primary")
    {_, 0} = System.cmd("git", ["clone", "-q", remote, primary])
    {_, 0} = System.cmd("git", ["-C", primary, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", primary, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", primary, "config", "commit.gpgsign", "false"])

    %{tmp: tmp, remote: remote, seed: seed, primary: primary}
  end

  defp advance_remote(seed, _remote, filename) do
    File.write!(Path.join(seed, filename), "content\n")
    {_, 0} = System.cmd("git", ["-C", seed, "add", filename])
    {_, 0} = System.cmd("git", ["-C", seed, "commit", "-q", "-m", "advance " <> filename])
    {_, 0} = System.cmd("git", ["-C", seed, "push", "-q", "origin", "main"])
  end

  defp head(path) do
    {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(out)
  end

  test "fast-forwards a clean checkout on the default branch to the new origin tip", %{
    seed: seed,
    remote: remote,
    primary: primary
  } do
    advance_remote(seed, remote, "ADVANCE.md")

    assert :ok = PrimarySync.fast_forward(primary, "main")
    assert head(primary) == head(seed)
    assert File.exists?(Path.join(primary, "ADVANCE.md"))
  end

  test "is a no-op when the checkout is already at the tip", %{primary: primary} do
    before = head(primary)
    assert :ok = PrimarySync.fast_forward(primary, "main")
    assert head(primary) == before
  end

  test "skips without touching the checkout when it has uncommitted changes", %{
    seed: seed,
    remote: remote,
    primary: primary
  } do
    advance_remote(seed, remote, "ADVANCE.md")
    before = head(primary)
    File.write!(Path.join(primary, "dirty.txt"), "wip\n")

    assert {:skipped, :uncommitted_changes} = PrimarySync.fast_forward(primary, "main")
    assert head(primary) == before
    refute File.exists?(Path.join(primary, "ADVANCE.md"))
  end

  test "skips without touching the checkout when it is on a different branch", %{
    seed: seed,
    remote: remote,
    primary: primary
  } do
    {_, 0} = System.cmd("git", ["-C", primary, "checkout", "-q", "-b", "human-wip"])
    advance_remote(seed, remote, "ADVANCE.md")
    before = head(primary)

    assert {:skipped, :not_on_default_branch} = PrimarySync.fast_forward(primary, "main")
    assert head(primary) == before
  end

  test "skips without touching the checkout when local main has diverged", %{
    seed: seed,
    remote: remote,
    primary: primary
  } do
    File.write!(Path.join(primary, "local_only.txt"), "local commit\n")
    {_, 0} = System.cmd("git", ["-C", primary, "add", "local_only.txt"])
    {_, 0} = System.cmd("git", ["-C", primary, "commit", "-q", "-m", "unpushed local work"])
    advance_remote(seed, remote, "ADVANCE.md")
    before = head(primary)

    assert {:skipped, :not_fast_forwardable} = PrimarySync.fast_forward(primary, "main")
    assert head(primary) == before
  end

  # bd-2rdfsh: how stale is the primary's LOCAL target branch (what a bare
  # `git log main` sees), and why would the post-merge sync leave it alone?
  describe "status/2" do
    defp fetch(path), do: {_, 0} = System.cmd("git", ["-C", path, "fetch", "-q", "origin"])

    test "an up-to-date checkout is 0 behind with no blocker", %{primary: primary} do
      assert {:ok, %{behind: 0, blocker: nil}} = PrimarySync.status(primary, "main")
    end

    test "counts how many commits local main is behind origin/main", %{
      seed: seed,
      remote: remote,
      primary: primary
    } do
      for n <- 1..3, do: advance_remote(seed, remote, "A#{n}.md")
      fetch(primary)

      assert {:ok, %{behind: 3, blocker: nil, current_branch: "main"}} =
               PrimarySync.status(primary, "main")

      # Read-only: status never moves the checkout.
      refute File.exists?(Path.join(primary, "A1.md"))
    end

    test "names why a sync would skip: dirty tree, other branch, divergence", %{
      seed: seed,
      remote: remote,
      primary: primary
    } do
      advance_remote(seed, remote, "A1.md")
      fetch(primary)

      File.write!(Path.join(primary, "dirty.txt"), "wip\n")

      assert {:ok, %{behind: 1, blocker: :uncommitted_changes}} =
               PrimarySync.status(primary, "main")

      File.rm!(Path.join(primary, "dirty.txt"))

      {_, 0} = System.cmd("git", ["-C", primary, "checkout", "-q", "-b", "human-wip"])

      assert {:ok, %{behind: 1, blocker: :not_on_default_branch, current_branch: "human-wip"}} =
               PrimarySync.status(primary, "main")

      {_, 0} = System.cmd("git", ["-C", primary, "checkout", "-q", "main"])
      File.write!(Path.join(primary, "local_only.txt"), "local\n")
      {_, 0} = System.cmd("git", ["-C", primary, "add", "local_only.txt"])
      {_, 0} = System.cmd("git", ["-C", primary, "commit", "-q", "-m", "local"])

      assert {:ok, %{behind: 1, blocker: :not_fast_forwardable}} =
               PrimarySync.status(primary, "main")
    end

    test "errors when the local branch or the origin ref does not exist", %{primary: primary} do
      assert {:error, _} = PrimarySync.status(primary, "no-such-branch")
      assert {:error, _} = PrimarySync.status(Path.join(primary, "missing"), "main")
    end
  end

  test "returns an error for a path that is not a git repo" do
    tmp = Path.join(System.tmp_dir!(), "ps009-notrepo-#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:error, _reason} = PrimarySync.fast_forward(tmp, "main")
  end
end
