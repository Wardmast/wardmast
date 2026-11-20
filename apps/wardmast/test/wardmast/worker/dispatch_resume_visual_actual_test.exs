defmodule Wardmast.Worker.DispatchResumeVisualActualTest do
  @moduledoc """
  GitHub #1598: a worker restarted on a ticket whose CI is red on the visual job
  (a `send_back` resume, `worker resume` of a CI-red park) gets the head's own
  rendered images under `.arbiter/visual-actual/`, exactly as the Watchdog fix pass
  does. Driven through the real `Dispatch.resume/2` and `resume_session/2`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.{ResumeSlotFixture, StubMerger}
  alias Wardmast.Usage.Event, as: UsageEvent
  alias Wardmast.Worker
  alias Wardmast.Worker.Dispatch

  @repo ResumeSlotFixture.repo()
  @pr "https://example.test/pull/7"

  setup do
    ResumeSlotFixture.setup_repo!()
    StubMerger.reset()
    :ok
  end

  defp archive(files) do
    {:ok, {_, bin}} =
      :zip.create(
        ~c"a.zip",
        Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end),
        [:memory]
      )

    bin
  end

  defp parked!(visual?) do
    n = System.unique_integer([:positive])

    visual = %{
      "job" => "visual",
      "artifact_path" => "test-results",
      "baseline_dir" => "e2e",
      "baseline_suffix" => "-chromium-linux.png"
    }

    repos = if visual?, do: %{@repo => %{"visual_baselines" => visual}}, else: %{}

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rv-#{n}",
        prefix: "rv#{n}",
        config: %{"worker" => %{"repos" => repos}}
      })

    {:ok, task} = Ash.create(Issue, %{title: "cut off", workspace_id: ws.id})
    {:ok, first} = Dispatch.dispatch(task.id, force: true, repo: @repo, start_driver: false)
    :ok = Worker.fail(first.worker_pid, :review_gate_rejected)

    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: task.id,
        workspace_id: ws.id,
        repo: @repo,
        step: :work,
        provider: "claude",
        session_id: "sess-#{n}",
        occurred_at: DateTime.utc_now()
      })

    {:ok, task} = Issue.pr_opened(task.id, @pr)
    wt = first.worktree_path
    File.mkdir_p!(Path.join(wt, "e2e"))
    File.write!(Path.join(wt, "e2e/page-chromium-linux.png"), "page-0")
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: wt)
    %{task: task, wt: wt, head: String.trim(head)}
  end

  defp artifacts(sha, failed \\ ["visual"]) do
    StubMerger.set_job_artifacts(
      {:ok,
       %{
         sha: sha,
         failed_jobs: failed,
         archive: archive([{"test-results/a/page-actual.png", "page-1"}])
       }}
    )
  end

  defp resume(fun, task) do
    test = self()

    opts = [
      start_driver: false,
      ci_adapter: StubMerger,
      claude_start: fn session_opts ->
        send(test, {:spawned, session_opts})
        {:ok, :captured}
      end
    ]

    assert {:ok, %{worker_pid: pid}} = fun.(task.id, opts)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid, :normal) end)
    assert_receive {:spawned, session_opts}
    session_opts
  end

  defp staged(wt), do: Path.join(wt, ".arbiter/visual-actual/page-chromium-linux.png")

  for {label, fun} <- [briefing: &Dispatch.resume/2, session: &Dispatch.resume_session/2] do
    describe "#{label} resume" do
      test "stages the head's images and briefs them; commits nothing" do
        %{task: task, wt: wt, head: head} = parked!(true)
        artifacts(head)

        session_opts = resume(unquote(fun), task)

        assert File.read!(staged(wt)) == "page-1"
        assert inspect(session_opts) =~ ".arbiter/visual-actual/page-chromium-linux.png"
        assert File.read!(Path.join(wt, "e2e/page-chromium-linux.png")) == "page-0"
        {log, 0} = System.cmd("git", ["log", "--name-only", "--format="], cd: wt)
        refute log =~ "visual-actual"
      end

      test "images for another head are never staged" do
        %{task: task, wt: wt} = parked!(true)
        artifacts("some-older-head")

        resume(unquote(fun), task)

        refute File.exists?(staged(wt))
      end

      test "nothing is staged when the visual job did not fail or the repo has none" do
        %{task: task, wt: wt, head: head} = parked!(true)
        artifacts(head, ["lint"])
        resume(unquote(fun), task)
        refute File.exists?(staged(wt))
      end

      test "a repo without visual_baselines never asks the forge" do
        %{task: task, wt: wt, head: head} = parked!(false)
        artifacts(head)
        resume(unquote(fun), task)
        refute File.exists?(staged(wt))
      end
    end
  end
end
