defmodule Wardmast.Worker.PrivateCloneStaleRecordsTest do
  @moduledoc """
  A private clone moved aside by hand never runs the clean-up that drops its
  ledger entry and identity record. A later linked worktree at the same leaf
  must not be taken for a swapped clone (bd-1h0zhg, #1394).
  """
  use ExUnit.Case, async: false

  alias Wardmast.Test.GitFixture
  alias Wardmast.Worker.PrivateClone
  alias Wardmast.Worker.Worktree

  import GitFixture, only: [git!: 2]

  @branch "feature/bd-stale-records"

  setup do
    fixture = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    root = Wardmast.Config.Paths.worktree_root()
    {:ok, clone} = PrivateClone.create(fixture.checkout, @branch, "main")
    leaf = Path.basename(clone)
    ledger = Path.expand(root) <> ".private-clones/" <> leaf
    identity = Path.join([fixture.checkout, ".git", "arbiter-clones", leaf])
    assert File.exists?(ledger) and File.exists?(identity)

    # the coordinator's by-hand crash recovery: move the clone aside.
    aside = clone <> ".moved-aside"
    File.rename!(clone, aside)
    on_exit(fn -> File.rm_rf(aside) end)

    Map.merge(fixture, %{root: root, clone: clone, leaf: leaf, ledger: ledger, identity: identity})
  end

  describe "a linked worktree at a leaf with stale clone records" do
    test "create/3 drops the records; guard and settle accept its .git file", ctx do
      assert {:ok, path} =
               Worktree.create(ctx.checkout, @branch, "main", layout: :linked_worktree)

      assert path == ctx.clone
      assert File.regular?(Path.join(path, ".git"))

      refute File.exists?(ctx.ledger)
      refute File.exists?(ctx.identity)
      assert PrivateClone.guard(path) == :ok
      assert PrivateClone.settle(path) == :ok
    end

    test "even with the records still present, the tamper message names a stale record", ctx do
      # Bypass provisioning: a plain `git worktree add` leaves the records.
      git!(ctx.checkout, ["worktree", "add", "-q", "-b", @branch, ctx.clone, "origin/main"])
      assert File.exists?(ctx.ledger)

      assert {:error, {:tampered, why}} = PrivateClone.guard(ctx.clone)
      assert why =~ "stale clone record"
      assert {:error, {:tampered, why2}} = PrivateClone.settle(ctx.clone)
      assert why2 =~ "stale clone record"
      # the correct .git file is NOT set aside as `.git.tampered`
      assert File.regular?(Path.join(ctx.clone, ".git"))
      refute File.exists?(Path.join(ctx.clone, ".git.tampered"))
    end

    test "a genuinely replaced .git (pointing outside the primary's worktrees) is not 'stale'",
         ctx do
      File.mkdir_p!(ctx.clone)
      other = Path.join(System.tmp_dir!(), "arb-stale-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([other, ".git", "worktrees", "x"]))
      on_exit(fn -> File.rm_rf(other) end)
      File.write!(Path.join(ctx.clone, ".git"), "gitdir: #{other}/.git/worktrees/x\n")

      assert {:error, {:tampered, why}} = PrivateClone.guard(ctx.clone)
      refute why =~ "stale clone record"
    end
  end

  describe "stale_records/1 and retire_stale/1" do
    test "reports a ledger entry whose dir is missing, and retires it", ctx do
      assert [rec] = PrivateClone.stale_records(ctx.root, min_age_ms: 0)
      assert rec.leaf == ctx.leaf
      assert rec.reason =~ "missing"
      assert rec.ledger? and rec.identity?

      assert [^rec] = PrivateClone.retire_stale(ctx.root, min_age_ms: 0)
      refute File.exists?(ctx.ledger)
      refute File.exists?(ctx.identity)
      assert PrivateClone.stale_records(ctx.root, min_age_ms: 0) == []
    end

    test "reports an identity record with no ledger entry", ctx do
      File.rm!(ctx.ledger)
      assert [rec] = PrivateClone.stale_records(ctx.root, min_age_ms: 0, repos: [ctx.checkout])
      assert rec.identity? and not rec.ledger?
    end

    test "reports a ledger entry whose dir has no .git directory", ctx do
      git!(ctx.checkout, ["worktree", "add", "-q", "-b", @branch, ctx.clone, "origin/main"])
      assert [rec] = PrivateClone.stale_records(ctx.root, min_age_ms: 0)
      assert rec.reason =~ "no .git directory"
    end

    test "keeps the records of a live private clone", ctx do
      File.rename!(ctx.clone <> ".moved-aside", ctx.clone)
      assert PrivateClone.stale_records(ctx.root, min_age_ms: 0) == []
    end

    test "spares a record younger than min_age_ms", ctx do
      assert PrivateClone.stale_records(ctx.root) == []
    end
  end
end
