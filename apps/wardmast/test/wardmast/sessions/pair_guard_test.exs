defmodule Wardmast.Sessions.PairGuardTest do
  @moduledoc """
  bd-7p6a9o, acceptance 3: a pair session cannot push to the default branch or
  write the primary checkout.

  Two layers, both tested here against what they actually produce:

    * the pair-specific **deny rules** a pair session's Claude `settings.json`
      carries on top of the interactive floor, and
    * the **push guard** — a `pre-push` hook reached through an env-scoped
      `core.hooksPath` that only the session's own processes carry — exercised
      with real `git push`es against a real bare remote.
  """
  # async: false — `GitFixture.forge_and_checkout/0` points the worktree root
  # (Application env) at a private directory, and the guard's hooks lookup
  # reads it (`Worktree.hooks_dir/1`, through `PrivateClone.guard/1`).
  use ExUnit.Case, async: false

  alias Wardmast.Sessions.PairGuard
  alias Wardmast.Test.GitFixture

  @branch "feature/par-1-make-widgets-faster"

  describe "deny_rules/1" do
    setup do
      %{
        rules:
          PairGuard.deny_rules(%{
            branch: @branch,
            target_branch: "main",
            primary_checkout: "/srv/example/checkout"
          })
      }
    end

    test "denies pushing to the default branch, in the spellings an agent reaches for", %{
      rules: rules
    } do
      for rule <- [
            "Bash(git push origin main:*)",
            "Bash(git push origin HEAD:main:*)",
            "Bash(git push origin HEAD:refs/heads/main:*)",
            "Bash(git push -u origin main:*)",
            "Bash(git push --set-upstream origin main:*)"
          ] do
        assert rule in rules, "missing #{rule}"
      end
    end

    test "denies the ways round the push guard", %{rules: rules} do
      for rule <- [
            "Bash(git push --no-verify:*)",
            "Bash(git -c core.hooksPath:*)",
            "Bash(git config core.hooksPath:*)",
            "Bash(gh pr create:*)",
            "Bash(gh pr merge:*)"
          ] do
        assert rule in rules, "missing #{rule}"
      end
    end

    test "denies writing the primary checkout, with an absolute Edit rule", %{rules: rules} do
      # `//` is Claude Code's absolute-path form; a single leading `/` is read
      # relative to the settings file and would match nothing there.
      assert "Edit(//srv/example/checkout/**)" in rules
      assert "Bash(git -C /srv/example/checkout:*)" in rules
      assert "Bash(cd /srv/example/checkout:*)" in rules
    end

    test "with no primary checkout configured, no checkout rule is invented" do
      rules = PairGuard.deny_rules(%{branch: @branch, target_branch: "main"})

      refute Enum.any?(rules, &String.contains?(&1, "checkout"))
      assert "Bash(git push origin main:*)" in rules
    end

    test "falls back to main when the base branch is unknown" do
      rules = PairGuard.deny_rules(%{branch: @branch, target_branch: nil})
      assert "Bash(git push origin main:*)" in rules
    end
  end

  describe "the push guard" do
    setup do
      git = GitFixture.forge_and_checkout()
      worktree = Path.join(git.root, "wt")
      GitFixture.git!(git.checkout, ["worktree", "add", "-q", "-b", @branch, worktree, "main"])
      GitFixture.git!(worktree, ["config", "user.email", "pair@example.com"])
      GitFixture.git!(worktree, ["config", "user.name", "pair"])
      GitFixture.commit!(worktree, %{"feature.txt" => "pair work\n"}, "pair work")

      hooks = Path.join(git.root, "session-hooks")
      assert :ok = PairGuard.install_hooks(hooks, %{branch: @branch, worktree: worktree})

      %{git: git, worktree: worktree, hooks: hooks, env: PairGuard.git_env(hooks)}
    end

    defp push(worktree, env, args) do
      System.cmd("git", ["-C", worktree, "push" | args], env: env, stderr_to_stdout: true)
    end

    defp remote_sha(git, ref) do
      case System.cmd("git", ["-C", git.forge, "rev-parse", "--verify", "-q", ref],
             stderr_to_stdout: true
           ) do
        {sha, 0} -> String.trim(sha)
        _ -> nil
      end
    end

    test "the ticket's branch pushes", %{git: git, worktree: wt, env: env} do
      assert {_out, 0} = push(wt, env, ["-q", "origin", @branch])

      assert remote_sha(git, "refs/heads/#{@branch}") ==
               GitFixture.git!(wt, ["rev-parse", "HEAD"])
    end

    test "a push to the default branch is refused and main does not move", %{
      git: git,
      worktree: wt,
      env: env
    } do
      before = remote_sha(git, "refs/heads/main")

      assert {out, status} = push(wt, env, ["origin", "HEAD:main"])
      assert status != 0
      assert out =~ "may push only refs/heads/#{@branch}"
      assert remote_sha(git, "refs/heads/main") == before
    end

    test "a push to any other branch, or a tag, is refused", %{git: git, worktree: wt, env: env} do
      assert {_out, status} = push(wt, env, ["origin", "HEAD:refs/heads/elsewhere"])
      assert status != 0
      assert remote_sha(git, "refs/heads/elsewhere") == nil

      GitFixture.git!(wt, ["tag", "v9"])
      assert {_out, status} = push(wt, env, ["origin", "v9"])
      assert status != 0
    end

    test "deleting the ticket's branch is refused", %{git: git, worktree: wt, env: env} do
      assert {_out, 0} = push(wt, env, ["-q", "origin", @branch])
      assert {_out, status} = push(wt, env, ["origin", "--delete", @branch])
      assert status != 0
      assert remote_sha(git, "refs/heads/#{@branch}") != nil
    end

    test "without the session's env, git is untouched (the guard is the session's alone)", %{
      git: git,
      worktree: wt
    } do
      assert {_out, 0} = push(wt, [], ["-q", "origin", "HEAD:refs/heads/elsewhere"])
      assert remote_sha(git, "refs/heads/elsewhere") != nil
    end

    test "the repo's own hooks still run behind the guard", %{git: git, worktree: wt, env: env} do
      repo_hooks =
        GitFixture.git!(git.checkout, [
          "rev-parse",
          "--path-format=absolute",
          "--git-path",
          "hooks"
        ])

      File.mkdir_p!(repo_hooks)
      marker = Path.join(git.root, "repo-pre-push-ran")
      commit_marker = Path.join(git.root, "repo-pre-commit-ran")

      write_hook!(repo_hooks, "pre-push", "touch #{marker}")
      write_hook!(repo_hooks, "pre-commit", "touch #{commit_marker}")

      assert {_out, 0} = push(wt, env, ["-q", "origin", @branch])
      assert File.exists?(marker)

      File.write!(Path.join(wt, "more.txt"), "more\n")
      GitFixture.git!(wt, ["add", "more.txt"])

      assert {_out, 0} =
               System.cmd("git", ["-C", wt, "commit", "-q", "-m", "more"],
                 env: env,
                 stderr_to_stdout: true
               )

      assert File.exists?(commit_marker)
    end

    test "a failing repo pre-push hook still fails the push", %{git: git, worktree: wt, env: env} do
      repo_hooks =
        GitFixture.git!(git.checkout, [
          "rev-parse",
          "--path-format=absolute",
          "--git-path",
          "hooks"
        ])

      File.mkdir_p!(repo_hooks)
      write_hook!(repo_hooks, "pre-push", "echo repo-hook-says-no >&2; exit 3")

      assert {out, status} = push(wt, env, ["origin", @branch])
      assert status != 0
      assert out =~ "repo-hook-says-no"
    end

    defp write_hook!(dir, name, body) do
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\n#{body}\n")
      File.chmod!(path, 0o755)
    end
  end
end
