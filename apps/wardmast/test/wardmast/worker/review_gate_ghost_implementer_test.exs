defmodule Wardmast.Worker.ReviewGateGhostImplementerTest do
  @moduledoc """
  bd-c845gp / GitHub #1657: a ReviewGate implementer whose start fails after its
  worker was registered (`:starting`, no agent) used to stay registered for good —
  a ghost `<task>#review#impl<N>` run that `worker_list` reported as the ticket's
  current run, and that the next fix round for the same ticket was handed back
  (`{:error, {:already_started, pid}}`) instead of a fresh implementer.
  """

  use Wardmast.DataCase, async: false

  import ExUnit.CaptureLog
  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.CircuitBreaker
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.{ClaudeSession, PrivateClone, ReviewGate}
  alias Wardmast.Workers.Run

  require Ash.Query

  @two_rounds Path.expand("../../fixtures/review_two_rounds.sh", __DIR__)
  @revise_hang Path.expand("../../fixtures/revise_hang.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp = Path.join(System.tmp_dir!(), "rg-ghost-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)
    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-ghost-#{System.unique_integer([:positive])}",
        prefix: "rg",
        config: %{"review" => %{"required" => true, "require_ci_green" => false}}
      })

    %{repo: repo, tmp: tmp, ws: ws}
  end

  test "an implementer start that fails leaves no registered worker and no live run row", ctx do
    {start, _calls} = stub_start([{:error, :boom}])
    rig = rig(ctx, "feature/rg-1")
    impl_id = rig.task.id <> "#review#impl1"

    capture_log(fn ->
      gate = start_gate(rig, ctx, session_start: start, fix_refusal_max_retries: 0)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, Wardmast.Test.Timing.scale(10_000)
    end)

    assert Worker.whereis(impl_id) == nil
    assert [%Run{state: :finished}] = runs_for(impl_id)
  end

  test "a ghost implementer left in :starting is replaced, not handed back to the round", ctx do
    rig = rig(ctx, "feature/rg-2")
    impl_id = rig.task.id <> "#review#impl1"

    {:ok, ghost} =
      Worker.start(
        task_id: impl_id,
        repo: "trib/repo",
        workspace_id: nil,
        meta: %{role: :implementer, revises: rig.task.id}
      )

    assert %{state: :starting} = Worker.state(ghost)
    ghost_ref = Process.monitor(ghost)

    capture_log(fn ->
      gate = start_gate(rig, ctx, fix_refusal_max_retries: 0)
      wait_until(fn -> live_impl?(gate) end)

      assert_receive {:DOWN, ^ghost_ref, :process, ^ghost, _}, Wardmast.Test.Timing.scale(5_000)
      assert Worker.whereis(impl_id) != ghost
      assert :sys.get_state(gate).phase == :revising
      stop_gate(gate)
    end)

    assert Enum.all?(runs_for(impl_id), &(&1.state == :finished))
  end

  # GitHub #1657 (bd-c22gf1): a conflict-resolve pass is no reviewer verdict either.
  # Its implementer failing to start was delivered as REQUEST_CHANGES — "not
  # converged after 1 round(s)" with no `review_gate_rounds` row.
  test "a conflict-resolve pass whose implementer cannot start is no REQUEST_CHANGES", ctx do
    Wardmast.Test.StubFixRoundDispatcher.reset()
    rig = rig(ctx, "feature/rg-3")

    # main moves and conflicts with the branch's feature.txt
    git!(["checkout", "-q", "main"], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "main work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "main change"], ctx.repo)
    git!(["push", "-q", "origin", "main"], ctx.repo)

    refused = {:not_a_private_clone, "/wt", :not_a_private_clone}

    log =
      capture_log(fn ->
        gate =
          start_gate(rig, ctx,
            session_start: fn _opts -> {:error, refused} end,
            fix_refusal_max_retries: 0
          )

        ref = Process.monitor(gate)
        assert_receive {:DOWN, ^ref, :process, ^gate, _}, Wardmast.Test.Timing.scale(15_000)
      end)

    # the conflict-resolve pass is what failed to start, not the reviewer
    assert log =~ "conflict-resolve pass 1/"
    assert log =~ "implementer could not be spawned"

    issue = Ash.get!(Issue, rig.task.id)
    assert issue.review_gate_state["verdict"] == "no_verdict"
    assert Wardmast.Test.StubFixRoundDispatcher.dispatch_count() == 0

    assert Wardmast.ReviewGate.Round |> Ash.read!() |> Enum.filter(&(&1.task_id == rig.task.id)) ==
             []

    assert Worker.whereis(rig.task.id <> "#review#impl1") == nil
  end

  defp runs_for(task_id) do
    Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
  end

  # ---- helpers -----------------------------------------------------------

  # The first call (the reviewer) is real; then each scripted result is returned in turn
  # and, once the script is spent, the real start runs.
  defp stub_start(script) do
    {:ok, agent} = Agent.start_link(fn -> %{n: 0, script: script} end)

    start = fn opts ->
      step =
        Agent.get_and_update(agent, fn %{n: n, script: s} = st ->
          cond do
            n == 0 -> {:real, %{st | n: 1}}
            s == [] -> {:real, %{st | n: n + 1}}
            true -> {hd(s), %{st | n: n + 1, script: tl(s)}}
          end
        end)

      if step == :real, do: ClaudeSession.start(opts), else: step
    end

    {start, agent}
  end

  defp live_impl?(gate) do
    case :sys.get_state(gate) do
      %{current_id: id} when is_binary(id) -> Worker.whereis(id) != nil
      _ -> false
    end
  end

  defp stop_gate(gate) do
    ref = Process.monitor(gate)

    try do
      GenServer.stop(gate, :normal)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^gate, _}, Wardmast.Test.Timing.scale(5_000)
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "refused fix round",
        workspace_id: ctx.ws.id,
        issue_type: :feature
      })

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["push", "-q", "origin", branch], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    {:ok, wt} = PrivateClone.attach(ctx.repo, branch, "main")
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["fetch", "-q", "origin", branch], wt)
    git!(["branch", "-q", "--set-upstream-to=origin/" <> branch, branch], wt)

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: branch,
          repo_path: ctx.repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    %{task: task, branch: branch, wt: wt, author: author}
  end

  defp start_gate(rig, ctx, opts) do
    {:ok, gate} =
      ReviewGate.start(
        Keyword.merge(
          [
            author: rig.author,
            task_id: rig.task.id,
            workspace_id: ctx.ws.id,
            repo: "trib/repo",
            worktree_path: rig.wt,
            branch: rig.branch,
            target_branch: "main",
            timeout_ms: 15_000,
            command: [@two_rounds, Path.join(ctx.tmp, "marker-#{rig.task.id}"), rig.branch],
            command_provider: "claude",
            revise_command: [@revise_hang],
            rounds: 2
          ],
          opts
        )
      )

    gate
  end

  defp wait_until(fun, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + Wardmast.Test.Timing.scale(timeout)
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
