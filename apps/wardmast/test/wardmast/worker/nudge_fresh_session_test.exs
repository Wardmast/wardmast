defmodule Wardmast.Worker.NudgeFreshSessionTest do
  @moduledoc """
  A gate nudge relaunch (commit gate / pre-push) splices `--resume <sid>` into the
  stashed claude argv. When that session's history is gone the CLI dies at once
  with "No conversation found with session ID" and the attempt is burned. The
  relaunch must check the session first and start a fresh, briefed session when
  it is missing; and a "No conversation found" exit that still happens gets one
  immediate fresh retry that is not counted as a nudge attempt.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.{SessionHistory, Worktree}

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  setup do
    tmp = Path.join(System.tmp_dir!(), "nudge-fresh-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    remote = Path.join(tmp, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)

    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"gate/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "nf-ws-#{System.unique_integer([:positive])}",
        prefix: "nf",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "nudge task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    branch = "bd-gate/#{task.id}"
    {:ok, path} = Worktree.create(repo, branch, "main")
    File.write!(Path.join(path, "forgotten.txt"), "uncommitted\n")

    sid = Ecto.UUID.generate()
    %{tmp: tmp, repo: repo, task: task, path: path, branch: branch, sid: sid}
  end

  defp start_worker(ctx) do
    {:ok, pid} =
      Worker.start(
        task_id: ctx.task.id,
        repo: "gate/repo",
        workspace_id: ctx.task.workspace_id,
        meta: %{
          branch: ctx.branch,
          repo_path: ctx.repo,
          worktree_path: ctx.path,
          target_branch: "main",
          merge_title: "Merge #{ctx.task.id}",
          review_spawn: false,
          commit_nudge_cap: 1
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  # A fake claude: logs its argv, then either dies the way `claude --resume` of a
  # missing session does (`die_on_resume`) or signals done.
  defp open_session(pid, ctx, die_on_resume?) do
    log = Path.join(ctx.tmp, "argv.log")

    script =
      """
      echo "$*" | tr '\\n' ' ' >> #{log}; echo >> #{log}
      case "$*" in
        *--resume*) if [ "#{die_on_resume?}" = true ]; then echo "No conversation found with session ID: x"; exit 1; fi;;
      esac
      printf 'arb %s\\n' done; sleep 0.3
      """

    {:ok, _port} =
      Wardmast.Worker.ClaudeSession.start(
        owner: pid,
        worktree_path: ctx.path,
        command: ["sh", "-c", script, "sh", "--print", "original prompt", "--session-id", ctx.sid]
      )

    log
  end

  defp launches(log), do: log |> File.read!() |> String.split("\n", trim: true)

  defp wait_finished(pid) do
    wait_until(fn -> match?(%{state: :finished}, Worker.state(pid)) end)
  end

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      fun.() || (Process.sleep(20) && false)
    end)
    |> Enum.find(fn ok -> ok || System.monotonic_time(:millisecond) > deadline end)
    |> then(&(&1 || flunk("condition not met within timeout")))
  end

  test "a nudge relaunch of a session with no history starts a fresh session, not --resume",
       ctx do
    pid = start_worker(ctx)
    log = open_session(pid, ctx, false)
    wait_finished(pid)

    [first, second | _] = launches(log)
    assert first =~ "--session-id #{ctx.sid}"
    refute second =~ "--resume"
    assert second =~ "--session-id"
    refute second =~ "--session-id #{ctx.sid}"
    assert second =~ "no longer available"
  end

  test "a nudge relaunch still resumes a session whose history exists", ctx do
    File.mkdir_p!(SessionHistory.store_dir())
    File.write!(SessionHistory.store_path(ctx.sid), "{}\n")
    on_exit(fn -> File.rm(SessionHistory.store_path(ctx.sid)) end)

    pid = start_worker(ctx)
    log = open_session(pid, ctx, false)
    wait_finished(pid)

    [_first, second | _] = launches(log)
    assert second =~ "--resume #{ctx.sid}"
  end

  test "a 'No conversation found' exit gets one fresh retry that is not a nudge attempt",
       ctx do
    File.mkdir_p!(SessionHistory.store_dir())
    File.write!(SessionHistory.store_path(ctx.sid), "{}\n")
    on_exit(fn -> File.rm(SessionHistory.store_path(ctx.sid)) end)

    pid = start_worker(ctx)
    log = open_session(pid, ctx, true)
    wait_finished(pid)

    [first, second, third] = launches(log)
    assert first =~ "--session-id #{ctx.sid}"
    assert second =~ "--resume #{ctx.sid}"
    refute third =~ "--resume"
    assert third =~ "--session-id"

    meta = Worker.state(pid).meta
    # The nudge (cap 1) was attempted once; the fresh retry did not count.
    assert meta.commit_nudge_attempts == 1
    assert meta.fresh_session_retries == 1
  end
end
