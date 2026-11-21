defmodule Wardmast.Worker.RemoteResumePushTest do
  @moduledoc """
  bd-361rwu (#1316) — end to end, against real git repos with a real bare origin: a
  send-back resume on a cluster node prints `arb done` before the node's final checkout
  upload lands. The agent's new commit arrives with the exit; the commit gate and
  ReviewGate must then see, push and review THAT head, and the "produced no new commit"
  escalation must stay quiet. The node upload is simulated by committing in the home clone
  between `arb done` and the exit message the executor delivers (`:__worker_stopped__`).
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Wardmast.Messages.Message
  alias Wardmast.ReviewGate.Resolutions
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.ReviewGate

  @push_check Path.expand("../../fixtures/review_push_check.sh", __DIR__)
  @handle {:remote, {"node-a", "run-1", :ref}}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "rr-push-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)
    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rr-push-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "send-back task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    branch = "feature/sb"
    git!(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "first\n")
    git!(["add", "feature.txt"], repo)
    git!(["commit", "-q", "-m", "feature work"], repo)
    git!(["checkout", "-q", "main"], repo)

    wt = Path.join(tmp, "wt")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", branch], wt)
    old_head = sha(wt, "HEAD")

    {:ok, _} =
      Resolutions.record(
        %{task_id: task.id, decision: :send_back, reasoning: "add the edge", head_sha: old_head},
        resume: false
      )

    %{repo: repo, ws: ws, task: task, branch: branch, wt: wt, old_head: old_head}
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

  defp remote_head(repo, branch) do
    {out, 0} = System.cmd("git", ["-C", repo, "ls-remote", "--heads", "origin", branch])
    out |> String.split() |> List.first()
  end

  defp escalations(ws, task) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task.id))
  end

  defp put_session(pid, session) do
    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, @handle, session)}
    end)
  end

  defp wait_until(fun, timeout \\ 5_000) do
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

  test "the node's final commit is pushed and is the head the gate reviews",
       %{repo: repo, ws: ws, task: task, branch: branch, wt: wt, old_head: old_head} do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
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
    put_session(author, %{exit_status: nil})

    send(author, {:__claude_session_done__, "arb done"})
    _ = :sys.get_state(author)

    # `arb done` with the node run still live: the worker waits, nothing is reviewed yet.
    refute match?(%{waiting_on: :review_gate}, Worker.state(author))

    # The node's final checkout upload lands with the exit.
    File.write!(Path.join(wt, "edge.txt"), "the needs edge\n")
    git!(["add", "edge.txt"], wt)
    git!(["commit", "-q", "-m", "add the needs edge"], wt)
    new_head = sha(wt, "HEAD")
    refute new_head == old_head

    put_session(author, %{exit_status: 0, remote_outcome: %{checkout_failed?: false}})
    send(author, {:__worker_stopped__, @handle})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    {:ok, _gate} =
      ReviewGate.start(
        author: author,
        task_id: task.id,
        workspace_id: ws.id,
        repo: "trib/repo",
        worktree_path: wt,
        branch: branch,
        target_branch: "main",
        timeout_ms: 15_000,
        command: [@push_check, branch, "ROUND1"]
      )

    # The reviewer fixture only APPROVEs a head that is on origin/<branch>.
    wait_until(fn -> Ash.get!(Issue, task.id).last_reviewed_sha == new_head end, 20_000)

    assert remote_head(repo, branch) == new_head
    assert escalations(ws, task) == []
  end

  test "a resume that adds no commit still pages \"no new commit\"",
       %{ws: ws, task: task, old_head: old_head} do
    assert :flagged =
             Wardmast.Worker.SendBackBrief.flag_unchanged_head(task.id, ws.id, old_head)

    assert [msg] = escalations(ws, task)
    assert msg.subject =~ "no new commit"
  end
end
