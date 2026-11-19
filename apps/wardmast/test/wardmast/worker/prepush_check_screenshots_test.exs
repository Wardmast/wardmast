defmodule Wardmast.Worker.PrepushCheckScreenshotsTest do
  @moduledoc """
  bd-adrym0: the commit gate checks the screenshots plan at `arb done`, even for a repo with no
  pre-push recipe. A UI diff with a missing or invalid plan is a red step; a valid skip passes.
  """

  use Wardmast.DataCase, async: false

  # Linux-only: fails on a macOS-like host (no /proc, GNU `timeout`, `setsid`, ...); excluded on darwin by test_helper.exs.
  @moduletag :linux

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.Worktree

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)

    remote = Path.join(dir, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)
    {repo, remote}
  end

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "prepush-gate-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    {repo, remote} = init_repo(tmp)

    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"gate/repo" => repo})

    on_exit(fn -> File.rm_rf(tmp) end)

    %{repo: repo, remote: remote, tmp: tmp}
  end

  defp workspace(worker_config) do
    config = %{"review" => %{"required" => true}}
    config = if worker_config, do: Map.put(config, "worker", worker_config), else: config

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pp-ws-#{System.unique_integer([:positive])}",
        prefix: "pp",
        config: config
      })

    ws
  end

  defp committed_worktree(repo, branch) do
    {:ok, path} = Worktree.create(repo, branch, "main")
    {_, 0} = git(["config", "user.email", "wt@example.com"], path)
    {_, 0} = git(["config", "user.name", "WT"], path)
    {_, 0} = git(["config", "commit.gpgsign", "false"], path)
    File.write!(Path.join(path, "real_work.txt"), "real\n")
    {_, 0} = git(["add", "real_work.txt"], path)
    {_, 0} = git(["commit", "-q", "-m", "real work"], path)
    path
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "prepush task", workspace_id: ws.id, issue_type: :feature})

    put_state!(task, :active)
  end

  defp start_worker(task, repo, path, extra_meta) do
    meta =
      Map.merge(
        %{
          branch: "bd-gate/#{task.id}",
          repo_path: repo,
          worktree_path: path,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_spawn: false,
          commit_nudge_cap: 0
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "gate/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp done(pid), do: send(pid, {:__claude_session_done__, "arb " <> "done"})

  defp failed?(pid), do: match?(%{state: :finished, outcome: :failed}, Worker.state(pid))

  defp at_review_gate?(pid),
    do: match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid))

  @screenshots %{
    "ui_paths" => ["real_work.txt"],
    "start_cmd" => "true"
  }

  describe "screenshots plan at arb done (no pre-push recipe)" do
    test "a UI diff with no plan is a red step; nothing is routed on", %{repo: repo} do
      ws = workspace(%{"screenshots" => @screenshots})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.commit_gate_reason == :prepush_failed

      assert Enum.any?(
               snap.meta.prepush_steps,
               &(&1.name == "screenshots plan" and &1.status == :failed)
             )

      assert {_, 0} = git(["check-ignore", ".arbiter/screenshots.json"], path)
    end

    test "a valid skip passes and its sha is kept on the run", %{repo: repo} do
      ws = workspace(%{"screenshots" => @screenshots})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")
      File.mkdir_p!(Path.join(path, ".arbiter"))
      body = ~s({"version":1,"skip":"copy only"})
      File.write!(Path.join(path, ".arbiter/screenshots.json"), body)

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert Worker.state(pid).meta.screenshots_plan_sha ==
               Wardmast.Screenshots.PlanCheck.sha(body)

      File.rm_rf!(Path.join(Wardmast.Screenshots.PlanCheck.store_root(), task.id))
    end
  end
end
