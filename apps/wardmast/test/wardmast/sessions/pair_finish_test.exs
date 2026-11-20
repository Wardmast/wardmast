defmodule Wardmast.Sessions.PairFinishTest do
  @moduledoc """
  bd-7p6a9o, acceptance 4 — tested at the completion seam: a pair session's
  **Done** runs the commit gate (everything committed, the repo's pre-push
  checks green), then hands the branch to the same completion path a worker's
  `arb done` takes. The PR is labelled `pair-authored`; a workspace that
  requires review sends it through the ReviewGate like any worker PR, and one
  that does not opens it and hands it to the ticket's Watchdog. A refused Done
  leaves the session — and its claim — live, so the pair can fix and retry.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Test.SessionEnv
  alias Wardmast.Test.SessionRunnerStub
  alias Wardmast.Test.StubMerger
  alias Wardmast.Worker.BranchNamer
  alias Wardmast.Worker.ReviewGate
  alias Wardmast.Worker.Watchdog

  setup do
    SessionEnv.sandbox("pair-finish")
    SessionRunnerStub.reset()
    StubMerger.reset()
    git = GitFixture.forge_and_checkout()
    {:ok, git: git}
  end

  defp ticket!(git, config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-finish-#{System.unique_integer([:positive])}",
        prefix: "pf#{System.unique_integer([:positive])}",
        config:
          Map.merge(
            %{
              "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
            },
            config
          )
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Make widgets faster",
        acceptance: "- faster",
        workspace_id: ws.id,
        repo: "widget",
        issue_type: :feature
      })

    issue = put_state!(issue, :queued)
    {:ok, %{session: session}} = Pair.open(issue, runner: SessionRunnerStub)
    on_exit(fn -> stop(Watchdog.whereis(issue.id)) end)

    %{ws: ws, issue: issue, session: session}
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # The merge overrides the worker-path tests use: the stub forge, and a fast
  # Watchdog.
  defp finish(issue, ws, completion \\ %{}) do
    Pair.finish(issue.id,
      runner: SessionRunnerStub,
      completion:
        Map.merge(
          %{
            merger_adapter_override: StubMerger,
            merger_workspace_override: ws,
            watchdog_interval_ms: 20,
            watchdog_initial_delay_ms: 0
          },
          completion
        )
    )
  end

  defp remote_branch(git, branch) do
    case System.cmd(
           "git",
           ["-C", git.forge, "rev-parse", "--verify", "-q", "refs/heads/#{branch}"],
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp pair_run(task_id) do
    Wardmast.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id and role == "pair")
    |> Ash.read!()
    |> List.first()
  end

  describe "the commit gate refuses, and the session stays live" do
    test "uncommitted changes", %{git: git} do
      %{ws: ws, issue: issue, session: session} = ticket!(git)
      File.write!(Path.join(session.cwd, "loose.txt"), "not committed\n")

      assert {:error, {:commit_gate, :uncommitted}} = finish(issue, ws)
      assert {:ok, %{id: id}} = Pair.live_session(issue.id)
      assert id == session.id
      assert Ash.get!(Issue, issue.id).state == :queued
    end

    test "a branch with nothing on it", %{git: git} do
      %{ws: ws, issue: issue} = ticket!(git)

      assert {:error, {:commit_gate, :no_commits}} = finish(issue, ws)
      assert {:ok, _live} = Pair.live_session(issue.id)
    end

    # bd-2rdfsh: the checkout's LOCAL main stalled 122 commits behind
    # origin/main, so an empty pair branch counted as 122 ahead, passed the gate,
    # pushed, failed the PR open with a 422 and started a ReviewGate round on an
    # empty diff. The gate must compare against origin/main.
    test "a branch with nothing on it is refused fast when the checkout's local main is stale",
         %{git: git} do
      GitFixture.commit!(git.seed, %{"a.txt" => "a\n"}, "upstream 1")
      GitFixture.commit!(git.seed, %{"b.txt" => "b\n"}, "upstream 2")
      GitFixture.commit!(git.seed, %{"c.txt" => "c\n"}, "upstream 3")
      GitFixture.git!(git.seed, ["push", "-q", "origin", "main"])

      marker = Path.join(git.root, "prepush-ran")

      config = %{
        "review" => %{"required" => true},
        "worker" => %{
          "pre_push_checks" => [%{"name" => "marker", "cmd" => "touch #{marker}"}]
        }
      }

      %{ws: ws, issue: issue, session: session} = ticket!(git, config)

      # The checkout's local main never moved; the pair branch is cut from
      # origin/main, so by the stale local ref it looks 3 commits ahead.
      local_main = GitFixture.git!(git.checkout, ["rev-parse", "main"])
      assert GitFixture.git!(session.cwd, ["rev-list", "--count", "main..HEAD"]) == "3"

      assert {:error, {:commit_gate, :no_commits}} = finish(issue, ws, %{review_spawn: false})

      refute File.exists?(marker), "pre-push checks must not run"
      assert remote_branch(git, BranchNamer.derive(issue)) == nil
      assert StubMerger.last_open() == nil
      reloaded = Ash.get!(Issue, issue.id)
      assert reloaded.state == :queued
      assert reloaded.review_gate_state in [nil, %{}]
      assert {:ok, _live} = Pair.live_session(issue.id)
      assert GitFixture.git!(git.checkout, ["rev-parse", "main"]) == local_main
    end

    test "a red pre-push check comes back with its output, and nothing is pushed", %{git: git} do
      config = %{
        "worker" => %{
          "pre_push_checks" => [%{"name" => "lint", "cmd" => "echo lint-failed-here; exit 3"}]
        }
      }

      %{ws: ws, issue: issue, session: session} = ticket!(git, config)
      GitFixture.commit!(session.cwd, %{"feature.txt" => "pair work\n"}, "pair work")

      assert {:error, {:prepush_failed, %{output: output}}} = finish(issue, ws)
      assert output =~ "lint-failed-here"
      assert remote_branch(git, BranchNamer.derive(issue)) == nil
      assert {:ok, _live} = Pair.live_session(issue.id)
      assert Ash.get!(Issue, issue.id).state == :queued
    end
  end

  describe "Done with no review required" do
    test "opens the PR labelled pair-authored, hands it to the Watchdog and ends the session",
         %{git: git} do
      %{ws: ws, issue: issue, session: session} = ticket!(git)
      branch = BranchNamer.derive(issue)
      sha = GitFixture.commit!(session.cwd, %{"feature.txt" => "pair work\n"}, "pair work")
      StubMerger.next_open_ref("!pair1")

      assert {:ok, %{route: :pr_opened}} = finish(issue, ws)

      assert %{branch: ^branch, opts: opts} = StubMerger.last_open()
      assert "pair-authored" in opts.labels
      assert remote_branch(git, branch) == sha

      reloaded = Ash.get!(Issue, issue.id)
      assert reloaded.state == :merging
      assert reloaded.pr_ref == "!pair1"
      assert is_pid(Watchdog.whereis(issue.id))

      # The session is over and its claim with it.
      assert Pair.live_session(issue.id) == :none
      assert {:ok, %{status: :ended, end_reason: "done"}} = Wardmast.Sessions.get(session.id)
      assert Pair.claimed_by(issue.id) == nil

      # The run history carries the pair session like a worker run.
      assert %{kind: :implement, outcome: :succeeded, mr_ref: "!pair1"} = pair_run(issue.id)
    end
  end

  describe "Done with review required" do
    test "enters the ReviewGate as any worker PR does, and an APPROVE opens it labelled",
         %{git: git} do
      %{ws: ws, issue: issue, session: session} =
        ticket!(git, %{"review" => %{"required" => true}})

      branch = BranchNamer.derive(issue)
      GitFixture.commit!(session.cwd, %{"feature.txt" => "pair work\n"}, "pair work")
      StubMerger.next_open_ref("!pair2")

      # `review_spawn: false`: the round is recorded and the gate is driven by
      # hand below, as the worker-path ReviewGate tests drive it.
      assert {:ok, %{route: :in_review}} = finish(issue, ws, %{review_spawn: false})

      round = Ash.get!(Issue, issue.id)
      assert round.state == :active

      assert %{"branch" => ^branch, "merge_opts" => %{"pair_authored" => true}} =
               round.review_gate_state

      assert Pair.live_session(issue.id) == :none

      # The reviewer approves; no author is resident, so the verdict lands on
      # the ticket and the merge path opens the PR — labelled.
      assert :ok = ReviewGate.deliver_verdict(issue.id, nil, {:approve, "VERDICT: APPROVE"})

      merged = Ash.get!(Issue, issue.id)
      assert merged.state == :merging
      assert merged.pr_ref == "!pair2"
      assert "pair-authored" in StubMerger.last_open().opts.labels
    end
  end

  describe "Done without a live pair session" do
    test "is refused", %{git: git} do
      %{ws: ws, issue: issue} = ticket!(git)
      {:ok, _} = Pair.close(issue.id, runner: SessionRunnerStub)

      assert {:error, :no_pair_session} = finish(issue, ws)
    end
  end
end
