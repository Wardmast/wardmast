defmodule Wardmast.Worker.RemoteResumePushTest do
  @moduledoc """
  bd-361rwu (#1316), acceptance criterion 1 end to end, against real git repos with a
  real bare `origin`: a send-back resume on a cluster node prints `arb done` while its
  container is still up, the agent's new commit reaches the home clone with the node's
  exit, and the branch must be pushed at THAT head with the ReviewGate seeing it — never
  the send-back head, and never a "produced no new commit" escalation.

  The node run is simulated as in `Wardmast.Worker.RemoteResumeDoneTest`; its exit is
  delivered through the same `{handle, {:exit_status, 0}}` message the executor sends, so
  it goes through `on_agent_stopped/3`. The node's final checkout upload is stood in for
  by a commit made in the worktree just before that exit.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Messages.Message
  alias Wardmast.ReviewGate.Resolutions
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.ReviewGate

  @push_check Path.expand("../../fixtures/review_push_check.sh", __DIR__)
  @handle {:remote, {"node-a", "run-1", :ref}}
  @branch "feature/resume-push"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "rrp-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    repo = init_repo(tmp)
    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"trib/repo" => repo})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rrp-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

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

  # A worktree on @branch holding the send-back head, already pushed to origin.
  defp send_back_worktree(repo, tmp) do
    git!(["checkout", "-q", "-b", @branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "first pass\n")
    git!(["add", "feature.txt"], repo)
    git!(["commit", "-q", "-m", "first pass"], repo)
    git!(["checkout", "-q", "main"], repo)

    wt = Path.join(tmp, "wt")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, @branch], cd: repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", @branch], wt)
    wt
  end

  defp commit_in(wt, name) do
    File.write!(Path.join(wt, name), "the send-back fix\n")
    git!(["add", name], wt)
    git!(["commit", "-q", "-m", "fix #{name}"], wt)
    sha(wt, "HEAD")
  end

  defp remote_head(tmp) do
    {out, 0} = System.cmd("git", ["-C", Path.join(tmp, "origin.git"), "rev-parse", @branch])
    String.trim(out)
  end

  defp wait_until(fun) do
    deadline = System.monotonic_time(:millisecond) + Wardmast.Test.Timing.scale(5_000)
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(20) && do_wait(fun, deadline)
    end
  end

  defp put_session(pid, session) do
    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, @handle, session)}
    end)
  end

  defp no_new_commit_messages(task) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task.id and &1.subject =~ "no new commit"))
  end

  defp resume_author(repo, wt, ws, send_back_head) do
    {:ok, task} =
      Ash.create(Issue, %{title: "send-back resume", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    {:ok, _} =
      Resolutions.record(%{
        task_id: task.id,
        decision: :send_back,
        reasoning: "add the fix",
        head_sha: send_back_head
      })

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: @branch,
          repo_path: repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    {task, author}
  end

  defp start_gate(author, task, ws, wt) do
    {:ok, gate} =
      ReviewGate.start(
        author: author,
        task_id: task.id,
        workspace_id: ws.id,
        repo: "trib/repo",
        worktree_path: wt,
        branch: @branch,
        target_branch: "main",
        timeout_ms: 15_000,
        command: [@push_check, @branch, "ROUND1"]
      )

    gate
  end

  test "the commit made before the node exit is the head pushed and reviewed",
       %{repo: repo, ws: ws, tmp: tmp} do
    wt = send_back_worktree(repo, tmp)
    old_head = sha(wt, "HEAD")
    {task, author} = resume_author(repo, wt, ws, old_head)

    put_session(author, %{
      exit_status: nil,
      task_id: task.id,
      topic: "rrp-#{task.id}",
      exited_at: nil,
      output_lines: []
    })

    send(author, {:__claude_session_done__, "arb done"})
    _ = :sys.get_state(author)

    # `arb done` with the node run still up: nothing is pushed or reviewed yet.
    refute match?(%{waiting_on: :review_gate}, Worker.state(author))
    assert remote_head(tmp) == old_head

    # The node's final checkout upload (the agent's new commit), then its exit.
    new_head = commit_in(wt, "fix.txt")
    refute new_head == old_head
    send(author, {@handle, {:exit_status, 0}})
    send(author, {:__worker_stopped__, @handle})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    start_gate(author, task, ws, wt)

    # The fixture APPROVEs only if the head it read is on origin/<branch>; the stamp is the
    # head the gate compared against the send-back head.
    wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == new_head end)
    assert remote_head(tmp) == new_head
    assert no_new_commit_messages(task) == []
  end

  test "a resume that adds no commit still escalates no new commit",
       %{repo: repo, ws: ws, tmp: tmp} do
    wt = send_back_worktree(repo, tmp)
    old_head = sha(wt, "HEAD")
    {task, author} = resume_author(repo, wt, ws, old_head)

    put_session(author, %{
      exit_status: nil,
      task_id: task.id,
      topic: "rrp-#{task.id}",
      exited_at: nil,
      output_lines: []
    })

    send(author, {:__claude_session_done__, "arb done"})
    _ = :sys.get_state(author)

    send(author, {@handle, {:exit_status, 0}})
    send(author, {:__worker_stopped__, @handle})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    start_gate(author, task, ws, wt)

    wait_until(fn -> no_new_commit_messages(task) != [] end)
    assert remote_head(tmp) == old_head
  end
end
