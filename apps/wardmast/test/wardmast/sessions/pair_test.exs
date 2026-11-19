defmodule Wardmast.Sessions.PairTest do
  @moduledoc """
  bd-7p6a9o: the **pair** session kind — a hands-on agent session bound to one
  ticket and worked together with the operator.

  Acceptance 1 (the kind exists; launching provisions or reuses the ticket's
  worktree and branch and mints a ticket-scoped token) and acceptance 5
  (ending without "done" leaves the worktree and the branch for a later worker
  or pair session to resume).
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.MCP.Scope
  alias Wardmast.Sessions
  alias Wardmast.Sessions.Layout
  alias Wardmast.Sessions.Pair
  alias Wardmast.Sessions.Refine
  alias Wardmast.Sessions.Session
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Test.SessionEnv
  alias Wardmast.Test.SessionRunnerStub
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.Worktree

  setup do
    SessionEnv.sandbox("pair")
    SessionRunnerStub.reset()
    git = GitFixture.forge_and_checkout(%{"README.md" => "readme\n", "CLAUDE.md" => "repo doc\n"})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-ws-#{System.unique_integer([:positive])}",
        prefix: "par",
        config: %{
          "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
        }
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Make widgets faster",
        description: "the widgets are slow",
        acceptance: "- widgets are faster",
        workspace_id: ws.id,
        repo: "widget",
        issue_type: :feature
      })

    issue = put_state!(issue, :queued)

    {:ok, ws: ws, issue: issue, git: git}
  end

  defp open!(issue, opts \\ []) do
    {:ok, result} = Pair.open(issue, Keyword.merge([runner: SessionRunnerStub], opts))
    result
  end

  defp git!(dir, args), do: GitFixture.git!(dir, args)

  describe "open/2 — the session kind and its binding" do
    test "launches a :pair session bound to the ticket and named after it", %{
      issue: issue,
      ws: ws
    } do
      %{session: session, reopened?: false} = open!(issue)

      assert session.kind == :pair
      assert session.issue_id == issue.id
      assert session.workspace_id == ws.id
      assert session.name == "Pair #{issue.id}: Make widgets faster"
      refute session.can_dispatch
      assert :pair in Session.kinds()
    end

    test "is visible wherever sessions are listed, like any session", %{issue: issue} do
      %{session: session} = open!(issue)
      assert Enum.any?(Sessions.list(), &(&1.id == session.id))
    end

    test "a second open reopens the same session, never a second one", %{issue: issue} do
      %{session: first, reopened?: false} = open!(issue)
      %{session: second, reopened?: true} = open!(issue)

      assert second.id == first.id
      assert {:ok, %Session{id: id}} = Pair.live_session(issue.id)
      assert id == first.id
    end

    test "a refine lookup never mistakes a pair session for a refine one", %{issue: issue} do
      %{session: _session} = open!(issue)

      assert Refine.live_session(issue.id) == :none
      assert Refine.latest_session(issue.id) == nil
    end
  end

  describe "open/2 — the ticket's worktree and branch" do
    test "runs in the ticket's own worktree, on the ticket's branch", %{issue: issue} do
      %{session: session} = open!(issue)

      branch = BranchNamer.derive(issue)
      assert session.cwd == Worktree.worktree_path(branch)
      assert File.dir?(session.cwd)
      assert git!(session.cwd, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch
    end

    test "reuses a worktree a worker already provisioned, commits and all", %{issue: issue} do
      branch = BranchNamer.derive(issue)
      %{session: first} = open!(issue)
      sha = GitFixture.commit!(first.cwd, %{"wip.txt" => "half done\n"}, "wip")
      {:ok, _} = Sessions.kill(first.id, runner: SessionRunnerStub)

      %{session: second, reopened?: false} = open!(issue)

      assert second.id != first.id
      assert second.cwd == first.cwd
      assert git!(second.cwd, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch
      assert git!(second.cwd, ["rev-parse", "HEAD"]) == sha
    end

    test "writes no doctrine into the worktree and leaves it clean", %{issue: issue} do
      %{session: session} = open!(issue)

      # The repo's own CLAUDE.md is the repo's, not ours to overwrite.
      assert File.read!(Path.join(session.cwd, "CLAUDE.md")) == "repo doc\n"
      refute File.exists?(Path.join(session.cwd, "AGENTS.md"))
      # The session's token lives in .mcp.json, which git never sees.
      assert File.exists?(Path.join(session.cwd, ".mcp.json"))
      assert git!(session.cwd, ["status", "--porcelain"]) == ""

      # The pair doctrine is the session's user-level memory instead.
      doctrine = session.config_dir |> Path.join("CLAUDE.md") |> File.read!()
      assert doctrine =~ "pair session"
      assert doctrine =~ issue.id
    end
  end

  describe "open/2 — the ticket-scoped token" do
    test "mints a worker-tier token bound to this ticket, never a coordinator one", %{
      issue: issue,
      ws: ws
    } do
      %{session: session} = open!(issue)

      assert {:ok, scope} = Scope.from_token(Sessions.mint_mcp_token(session))
      assert scope.tier == :worker
      assert scope.task_id == issue.id
      assert scope.workspace_id == ws.id
      assert scope.session_id == session.id
      refute scope.can_dispatch
    end

    test "the on-disk token stops verifying once the session ends", %{issue: issue} do
      %{session: session} = open!(issue)
      token = session.id |> Layout.mcp_token_path() |> File.read!() |> String.trim()

      assert {:ok, %Scope{tier: :worker}} = Scope.from_token(token)
      {:ok, _} = Sessions.kill(session.id, runner: SessionRunnerStub)
      assert {:error, :revoked} = Scope.from_token(token)
    end
  end

  describe "open/2 — the write scope (acceptance 3)" do
    test "the session's settings carry the pair deny rules over the interactive floor", %{
      issue: issue
    } do
      %{session: session} = open!(issue)

      deny =
        session.config_dir
        |> Path.join("settings.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["permissions", "deny"])

      assert "Bash(git push origin main:*)" in deny
      assert "Bash(git push --no-verify:*)" in deny
      assert "Bash(git push --force:*)" in deny

      checkout = Wardmast.Config.Paths.primary_checkout() |> Path.expand()
      assert "Edit(/#{checkout}/**)" in deny
    end

    test "the session's git refuses a push to the default branch from its worktree", %{
      issue: issue,
      git: git
    } do
      %{session: session} = open!(issue)
      branch = BranchNamer.derive(issue)

      script = session.id |> Layout.launch_script_path() |> File.read!()
      hooks = Path.join(Layout.session_dir(session.id), "git-hooks")
      assert script =~ "export GIT_CONFIG_KEY_0='core.hooksPath'"
      assert script =~ "export GIT_CONFIG_VALUE_0='#{hooks}'"

      GitFixture.commit!(session.cwd, %{"pair.txt" => "pair\n"}, "pair work")
      env = Wardmast.Sessions.PairGuard.git_env(hooks)
      main_before = git!(git.forge, ["rev-parse", "refs/heads/main"])

      assert {out, status} =
               System.cmd("git", ["-C", session.cwd, "push", "origin", "HEAD:main"],
                 env: env,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert out =~ "may push only refs/heads/#{branch}"
      assert git!(git.forge, ["rev-parse", "refs/heads/main"]) == main_before

      assert {_out, 0} =
               System.cmd("git", ["-C", session.cwd, "push", "-q", "origin", branch],
                 env: env,
                 stderr_to_stdout: true
               )
    end

    test "a worktree inside the primary checkout cannot host a pair session", %{issue: issue} do
      checkout = Wardmast.Config.Paths.primary_checkout()
      Wardmast.DataCase.put_app_env(:wardmast, :worktree_root, Path.join(checkout, "worktrees"))

      assert {:error, {:provisioning_failed, {:inside_primary_checkout, _path, _why}}} =
               Pair.open(issue, runner: SessionRunnerStub)

      assert Pair.live_session(issue.id) == :none
    end
  end

  describe "open/2 — eligibility" do
    test "a Backlog, Ready or In-progress ticket can be paired on", %{issue: issue} do
      assert Pair.eligible?(issue)
      assert Pair.eligible?(put_state!(issue, :backlog))
      assert Pair.eligible?(put_state!(issue, :active))
    end

    test "a merging, verifying or closed ticket cannot", %{issue: issue} do
      for state <- [:merging, :verifying, :closed] do
        ticket = put_state!(Ash.get!(Issue, issue.id), state)
        refute Pair.eligible?(ticket)
        assert {:error, :not_pairable} = Pair.open(ticket, runner: SessionRunnerStub)
        put_state!(ticket, :queued)
      end
    end

    test "a ticket whose repo resolves nowhere has no worktree to pair in" do
      # A workspace that registered no repo at all: there is nothing to default
      # the ticket's repo to, and nothing to check out.
      {:ok, ws} = Ash.create(Workspace, %{name: "pair-norepo", prefix: "pnr", config: %{}})

      {:ok, bare} =
        Ash.create(Issue, %{title: "no repo", workspace_id: ws.id, issue_type: :feature})

      assert {:error, :no_repo} = Pair.open(bare, runner: SessionRunnerStub)
      assert Pair.live_session(bare.id) == :none
    end

    test "an unknown ticket id is reported as such" do
      assert {:error, :issue_not_found} = Pair.open("par-nope", runner: SessionRunnerStub)
    end
  end

  describe "ending without done (acceptance 5)" do
    test "leaves the worktree and the branch, and a later open resumes from them", %{
      issue: issue,
      git: git
    } do
      %{session: session} = open!(issue)
      branch = BranchNamer.derive(issue)
      sha = GitFixture.commit!(session.cwd, %{"feature.txt" => "pair work\n"}, "pair work")
      git!(session.cwd, ["push", "-q", "origin", branch])

      assert {:ok, ended} = Pair.close(issue.id, runner: SessionRunnerStub)
      assert ended.status == :ended
      assert Pair.live_session(issue.id) == :none

      # Nothing was torn down: the worktree, its commit and the pushed branch.
      assert File.dir?(session.cwd)
      assert git!(session.cwd, ["rev-parse", "HEAD"]) == sha
      assert git!(git.forge, ["rev-parse", "refs/heads/#{branch}"]) == sha

      %{session: later} = open!(Ash.get!(Issue, issue.id))
      assert later.cwd == session.cwd
      assert git!(later.cwd, ["rev-parse", "HEAD"]) == sha
    end

    test "close with no live session says so", %{issue: issue} do
      assert {:error, :no_pair_session} = Pair.close(issue.id, runner: SessionRunnerStub)
    end
  end
end
