defmodule Wardmast.Worker.GitLayoutTest do
  @moduledoc "bd-4wy1w1 (P5): which git layout a worker checkout gets."
  use ExUnit.Case, async: true

  alias Wardmast.Agents.SecurityPolicy
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.GitLayout

  defp ws(security), do: %Workspace{config: %{"agent" => %{"security" => security}}}

  test "a container backend gets a private clone; bwrap and the default keep a linked worktree" do
    assert GitLayout.for_policy(
             SecurityPolicy.resolve(ws(%{"sandbox" => %{"backend" => "podman"}}))
           ) ==
             :private_clone

    assert GitLayout.for_policy(
             SecurityPolicy.resolve(ws(%{"sandbox" => %{"backend" => "bwrap"}}))
           ) ==
             :linked_worktree

    assert GitLayout.for_policy(SecurityPolicy.resolve(nil)) == :linked_worktree
  end

  test "for_workspace/3 resolves the policy the spawn will use: repo scope and dispatch override" do
    repo_scoped = ws(%{"repos" => %{"tonic" => %{"sandbox" => %{"backend" => "podman"}}}})

    assert GitLayout.for_workspace(repo_scoped, "tonic") == :private_clone
    assert GitLayout.for_workspace(repo_scoped, "other") == :linked_worktree

    assert GitLayout.for_workspace(ws(%{}), nil, %{"sandbox" => %{"backend" => "podman"}}) ==
             :private_clone
  end

  # bd-7ays3v: ReviewGate reviewers, fix passes and conflict passes are
  # container-capable, so each gets a private clone under podman.
  describe "the spawn kinds that run in a container (bd-7ays3v)" do
    @podman %{"sandbox" => %{"backend" => "podman"}}

    test "a reviewer gets a private clone when either backend is podman" do
      assert GitLayout.for_review_workspace(ws(@podman)) == :private_clone

      assert GitLayout.for_review_workspace(ws(%{"sandbox" => %{"review_backend" => "podman"}})) ==
               :private_clone

      repo_scoped = ws(%{"repos" => %{"tonic" => @podman}})
      assert GitLayout.for_review_workspace(repo_scoped, "tonic") == :private_clone
      assert GitLayout.for_review_workspace(repo_scoped, "other") == :linked_worktree
    end

    test "a reviewer under bwrap or the default keeps a linked worktree" do
      assert GitLayout.for_review_workspace(ws(%{"sandbox" => %{"backend" => "bwrap"}})) ==
               :linked_worktree

      assert GitLayout.for_review_workspace(nil) == :linked_worktree
    end

    test "fix and conflict passes resolve the implement backend, so podman is a private clone" do
      assert GitLayout.for_workspace(ws(@podman), "tonic") == :private_clone
      assert GitLayout.for_workspace(ws(%{}), "tonic") == :linked_worktree
    end
  end

  # bd-56z2wz: `sandbox.backend: auto` has no layout until placement (or an existing
  # checkout) says, so an unplaced auto policy is the primary's local layout.
  describe "sandbox.backend auto (bd-56z2wz)" do
    @auto %{"sandbox" => %{"backend" => "auto"}}

    @tag :tmp_dir
    test "existing/1 reads the layout already on disk", %{tmp_dir: dir} do
      linked = Path.join(dir, "linked")
      clone = Path.join(dir, "clone")
      stub = Path.join(dir, "stub")
      File.mkdir_p!(linked)
      File.write!(Path.join(linked, ".git"), "gitdir: /elsewhere/.git/worktrees/x\n")
      File.mkdir_p!(Path.join(clone, ".git"))
      File.mkdir_p!(Path.join(stub, ".arbiter"))

      assert GitLayout.existing(linked) == :linked_worktree
      assert GitLayout.existing(clone) == :private_clone
      assert GitLayout.existing(stub) == nil
      assert GitLayout.existing(Path.join(dir, "missing")) == nil
      assert GitLayout.existing(nil) == nil
    end

    test "an unplaced auto policy is the local layout, a configured podman local backend a clone" do
      assert GitLayout.for_workspace(ws(@auto)) == :linked_worktree

      podman_local = %{"sandbox" => %{"backend" => "auto", "local_backend" => "podman"}}
      assert GitLayout.for_workspace(ws(podman_local)) == :private_clone
    end

    @tag :tmp_dir
    test "for_checkout/3 keeps the layout of the checkout that exists", %{tmp_dir: dir} do
      linked = Path.join(dir, "linked")
      clone = Path.join(dir, "clone")
      File.mkdir_p!(linked)
      File.write!(Path.join(linked, ".git"), "gitdir: /elsewhere\n")
      File.mkdir_p!(Path.join(clone, ".git"))

      # a linked worktree stays one even when the local backend is a container
      podman_local = ws(%{"sandbox" => %{"backend" => "auto", "local_backend" => "podman"}})
      assert GitLayout.for_checkout(podman_local, nil, linked) == :linked_worktree
      assert GitLayout.for_checkout(ws(@auto), nil, clone) == :private_clone
      assert GitLayout.for_checkout(ws(@auto), nil, Path.join(dir, "none")) == :linked_worktree

      # a configured backend never reads the disk
      assert GitLayout.for_checkout(ws(@podman), nil, linked) == :private_clone
      assert GitLayout.for_checkout(ws(%{}), nil, clone) == :linked_worktree
    end

    @tag :tmp_dir
    test "concretize/2 fixes the policy to the checkout's backend", %{tmp_dir: dir} do
      clone = Path.join(dir, "clone")
      File.mkdir_p!(Path.join(clone, ".git"))
      policy = SecurityPolicy.resolve(ws(@auto))

      assert GitLayout.concretize(policy, clone).sandbox.backend == :podman
      assert GitLayout.concretize(policy, nil).sandbox.backend == :bwrap
    end
  end
end
