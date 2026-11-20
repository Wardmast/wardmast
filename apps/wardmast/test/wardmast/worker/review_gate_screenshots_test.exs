defmodule Wardmast.Worker.ReviewGateScreenshotsTest do
  @moduledoc """
  bd-84latk / GitHub #1328 — the ReviewGate's screenshot step, end to end through a real gate over
  real git: a UI change reaches the reviewer with its screenshots; a missing manifest sends the
  change back with the instruction; an infrastructure capture failure escalates and never loops
  the worker; a repo with no `screenshots` config is untouched.

  The capture itself is injected (`:screenshot_capture`): booting an app and Chromium is
  `Wardmast.Screenshots.Capture`'s own concern and has its own tests.
  """

  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Worker.ReviewGate

  @probe Path.expand("../../fixtures/review_ci_probe.sh", __DIR__)

  @screenshots %{"ui_paths" => ["**/*.txt"], "start_cmd" => "true"}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-shots-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:wardmast, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)
    %{repo: repo, tmp: tmp}
  end

  describe "a UI change with captured screenshots" do
    test "reaches the reviewer with them in its brief", ctx do
      before_png = Path.join(ctx.tmp, "home__before.png")
      after_png = Path.join(ctx.tmp, "home__after.png")
      File.write!(before_png, "png")
      File.write!(after_png, "png")

      capture = fn input, _opts ->
        send(ctx_pid(), {:captured, input})

        {:ok,
         %{
           pairs: [
             %{
               id: "home",
               title: "Home",
               viewport: "desktop",
               theme: "light",
               label: "Home · desktop · light",
               kind: :changed,
               before: %{status: :ok, file: before_png, name: "b.png", sha256: "x", bytes: 3},
               after: %{status: :ok, file: after_png, name: "a.png", sha256: "y", bytes: 3}
             }
           ],
           notes: nil
         }}
      end

      Process.put(:test_pid, self())
      rig = rig(ctx, new_ws(@screenshots), "feature/shots-1")
      gate = start_gate(rig, ctx, screenshot_capture: capture)

      wait_until(fn -> passes(rig) == 1 end)
      assert_received {:captured, %{head_sha: head, plan_path: plan} = input}
      assert String.starts_with?(rig.head, head)
      # bd-3glf2a: the branch whose mix.lock the offline deps cache trusts (no merge.base: main),
      # through the lifecycle's plan/3 with the gate's own capture history.
      assert input.default_branch == "main"
      # bd-adrym0: the copy the commit gate checked feeds the capture, not the live worktree file.
      assert plan ==
               Wardmast.Screenshots.PlanCheck.stored_path(
                 Wardmast.Screenshots.PlanCheck.store_root(),
                 rig.task.id
               )

      prompt = :sys.get_state(gate).current_prompt
      assert prompt =~ "UI SCREENSHOTS"
      assert prompt =~ before_png
      assert prompt =~ after_png
      assert prompt =~ "Home · desktop · light"
      stop_gate(gate)
    end
  end

  describe "a UI change with no manifest" do
    test "is sent back to the worker with the instruction to add one", ctx do
      failure = Failure.new(:manifest_missing, "the worker wrote no screenshots manifest")
      rig = rig(ctx, new_ws(@screenshots), "feature/shots-2")

      gate =
        start_gate(rig, ctx,
          rounds: 2,
          revise_command: ["sleep", "120"],
          screenshot_capture: fn _i, _o -> {:error, failure} end
        )

      wait_until(fn -> :sys.get_state(gate).phase == :revising end)

      assert passes(rig) == 0, "no reviewer is paid for before the worker adds a manifest"
      [entry | _] = :sys.get_state(gate).thread
      assert entry.body =~ ".arbiter/screenshots.json"
      assert entry.body =~ "NO-FILE-CHANGE:"
      stop_gate(gate)
    end
  end

  describe "the round after a send-back (CI already green, head unchanged)" do
    test "captures again and the re-review brief carries the screenshots", ctx do
      after_png = Path.join(ctx.tmp, "home__after.png")
      File.write!(after_png, "png")
      calls = :counters.new(1, [])
      Process.put(:test_pid, self())

      capture = fn input, _opts ->
        :counters.add(calls, 1, 1)
        send(ctx_pid(), {:captured, :counters.get(calls, 1), input.head_sha})

        case :counters.get(calls, 1) do
          1 ->
            {:error, Failure.new(:manifest_missing, "the worker wrote no screenshots manifest")}

          _ ->
            {:ok,
             %{
               pairs: [
                 %{
                   id: "home",
                   title: "Home",
                   viewport: "desktop",
                   theme: "light",
                   label: "Home · desktop · light",
                   kind: :added,
                   before: %{status: :absent, reason: "new page"},
                   after: %{status: :ok, file: after_png, name: "a.png", sha256: "y", bytes: 3}
                 }
               ],
               notes: nil
             }}
        end
      end

      rig = rig(ctx, new_ws(@screenshots), "feature/shots-5")

      gate =
        start_gate(rig, ctx,
          rounds: 3,
          revise_command: [Path.expand("../../fixtures/revise_non_file_fix.sh", __DIR__)],
          screenshot_capture: capture
        )

      # Round 1 is sent back; the worker's fix round leaves the head alone (CI is off, so the
      # round-2 gate proceeds straight away). Round 2 must still capture and brief the reviewer.
      wait_until(fn -> passes(rig) == 1 end, 30_000)

      assert_received {:captured, 1, _}
      assert_received {:captured, 2, _}
      prompt = :sys.get_state(gate).current_prompt
      assert prompt =~ "This is review round 2"
      assert prompt =~ "UI SCREENSHOTS"
      assert prompt =~ after_png
      stop_gate(gate)
    end
  end

  describe "an infrastructure capture failure" do
    test "escalates to the coordinator and does not send the change back", ctx do
      failure =
        Failure.new(:boot_failed, "the app failed to boot at the head (setup): no chromium",
          role: "after"
        )

      rig = rig(ctx, new_ws(@screenshots), "feature/shots-3")

      gate =
        start_gate(rig, ctx,
          rounds: 2,
          revise_command: ["sleep", "120"],
          screenshot_capture: fn _i, _o -> {:error, failure} end
        )

      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, Wardmast.Test.Timing.scale(20_000)

      assert passes(rig) == 0
      issue = Ash.get!(Issue, rig.task.id)
      assert issue.attention_cause == :screenshot_capture_failed
    end
  end

  describe "the capture lifecycle record (bd-8qj1sa)" do
    alias Wardmast.Screenshots.Captures

    test "writes a row per attempt: head, base, plan_hash, config_hash, state", ctx do
      Process.put(:test_pid, self())
      rig = rig(ctx, new_ws(@screenshots), "feature/shots-5")
      gate = start_gate(rig, ctx, screenshot_capture: fn _i, _o -> {:ok, %{pairs: []}} end)

      wait_until(fn -> passes(rig) == 1 end)
      assert [row] = Captures.list(rig.task.id)
      assert row.state == "captured"
      assert String.starts_with?(rig.head, row.head_sha)
      assert is_binary(row.base_sha) and is_binary(row.config_hash)
      assert is_binary(row.plan_hash), "the commit gate's stored plan is hashed"
      stop_gate(gate)
    end

    test "a new head cancels an in-flight capture and captures the new head", ctx do
      Process.put(:test_pid, self())
      rig = rig(ctx, new_ws(@screenshots), "feature/shots-6")

      capture = fn input, _opts ->
        send(ctx_pid(), {:capture_started, self(), input.head_sha})

        if String.starts_with?(rig.head, input.head_sha) do
          Process.sleep(:infinity)
        else
          {:ok, %{pairs: []}}
        end
      end

      # The real trigger: no test calls into the gate. The gate's own poll of `origin/<branch>`
      # finds the head a third party pushed while the capture was running.
      gate = start_gate(rig, ctx, screenshot_capture: capture, screenshot_head_poll_ms: 50)

      assert_receive {:capture_started, first, head1}, Wardmast.Test.Timing.scale(15_000)
      assert String.starts_with?(rig.head, head1)
      ref = Process.monitor(first)

      new_head = push_third_party_commit(ctx, rig)

      assert_receive {:DOWN, ^ref, :process, ^first, _}, Wardmast.Test.Timing.scale(10_000)

      assert_receive {:capture_started, _second, head2}, Wardmast.Test.Timing.scale(10_000)
      assert String.starts_with?(new_head, head2)
      wait_until(fn -> passes(rig) == 1 end)

      assert [old, new] = Captures.list(rig.task.id)
      assert {old.state, new.state} == {"superseded", "captured"}
      assert String.starts_with?(rig.head, old.head_sha)
      assert String.starts_with?(new_head, new.head_sha)
      assert sha(rig.wt, "HEAD") == new_head, "the review runs on the head that was captured"
      assert :sys.get_state(gate).head_sha == head2
      stop_gate(gate)
    end

    test "a head that has not moved leaves the capture running", ctx do
      Process.put(:test_pid, self())
      rig = rig(ctx, new_ws(@screenshots), "feature/shots-8")

      capture = fn input, _opts ->
        send(ctx_pid(), {:capture_started, self(), input.head_sha})
        Process.sleep(:infinity)
      end

      gate = start_gate(rig, ctx, screenshot_capture: capture, screenshot_head_poll_ms: 20)
      assert_receive {:capture_started, task, _head}, Wardmast.Test.Timing.scale(15_000)

      # Several polls later nothing was cancelled or restarted.
      for _ <- 1..5,
          do: send(gate, {:screenshot_head_poll, :sys.get_state(gate).screenshot_task.ref})

      _ = :sys.get_state(gate)

      assert Process.alive?(task)
      refute_received {:capture_started, _, _}
      assert [%{state: "running"}] = Captures.list(rig.task.id)
      stop_gate(gate)
    end

    test "max_captures_per_ticket is enforced by the gate", ctx do
      Process.put(:test_pid, self())
      block = Map.put(@screenshots, "limits", %{"max_captures_per_ticket" => 1})
      rig = rig(ctx, new_ws(block), "feature/shots-7")

      {:ok, spent} =
        Captures.begin_attempt(%{
          task_id: rig.task.id,
          head_sha: "0ld",
          base_sha: "b",
          config_hash: "c"
        })

      Captures.finish(spent, {:ok, %{pairs: []}})

      gate =
        start_gate(rig, ctx,
          screenshot_capture: fn _i, _o ->
            send(ctx_pid(), :capture_called)
            {:ok, %{pairs: []}}
          end
        )

      wait_until(fn -> passes(rig) == 1 end)
      refute_received :capture_called
      assert :sys.get_state(gate).current_prompt =~ "max_captures_per_ticket"
      stop_gate(gate)
    end
  end

  describe "a repo with no screenshots config" do
    test "keeps today's behaviour: no capture, the reviewer is dispatched", ctx do
      Process.put(:test_pid, self())
      rig = rig(ctx, new_ws(nil), "feature/shots-4")

      gate =
        start_gate(rig, ctx,
          screenshot_capture: fn _i, _o ->
            send(ctx_pid(), :capture_called)
            {:skipped, :no_ui_paths}
          end
        )

      wait_until(fn -> passes(rig) == 1 end)
      refute_received :capture_called
      refute :sys.get_state(gate).current_prompt =~ "UI SCREENSHOTS"
      stop_gate(gate)
    end
  end

  # The capture runs in a task spawned by the gate, so the test pid is stashed
  # in the closure's process dictionary-free way: via a named registration.
  defp ctx_pid, do: Process.get(:test_pid) || :persistent_term.get({__MODULE__, :pid})

  # ---- git rig -------------------------------------------------------------

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

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp rig(ctx, ws, branch) do
    :persistent_term.put({__MODULE__, :pid}, self())
    on_exit(fn -> :persistent_term.erase({__MODULE__, :pid}) end)

    {:ok, task} =
      Ash.create(Issue, %{title: "shots task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    wt = Path.join(ctx.tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: ctx.repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", branch], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", ctx.repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    %{
      task: task,
      ws: ws,
      branch: branch,
      wt: wt,
      head: sha(wt, "HEAD"),
      author: start_author(task, ws, ctx, branch, wt)
    }
  end

  # Another actor pushes a commit onto the ticket's branch on origin (from its own clone), the
  # way a human or a patrol fix pushing to the PR does. Returns the new full head sha.
  defp push_third_party_commit(ctx, rig) do
    bare = Path.join(ctx.tmp, "origin.git")
    other = Path.join(ctx.tmp, "other-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", "-b", rig.branch, bare, other])
    git!(["config", "user.email", "other@example.com"], other)
    git!(["config", "user.name", "Other"], other)
    git!(["config", "commit.gpgsign", "false"], other)
    File.write!(Path.join(other, "more.txt"), "third party\n")
    git!(["add", "more.txt"], other)
    git!(["commit", "-q", "-m", "third party push"], other)
    git!(["push", "-q", "origin", rig.branch], other)
    sha(other, "HEAD")
  end

  defp common_dir(rig) do
    {dir, 0} = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], rig.wt)
    String.trim(dir)
  end

  defp passes(rig) do
    case File.read(Path.join(common_dir(rig), "review_ci_passes")) do
      {:ok, n} ->
        case Integer.parse(String.trim(n)) do
          {count, ""} -> count
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp stop_gate(gate) do
    ref = Process.monitor(gate)
    GenServer.stop(gate, :normal)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}, Wardmast.Test.Timing.scale(5_000)
  end

  # ---- app rig -------------------------------------------------------------

  defp new_ws(screenshots) do
    worker =
      case screenshots do
        nil -> %{}
        block -> %{"repos" => %{"trib/repo" => %{"screenshots" => block}}}
      end

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-shots-#{System.unique_integer([:positive])}",
        prefix: "rs",
        config: %{
          "review" => %{"required" => true, "require_ci_green" => false},
          "review_gate" => %{"max_fix_rounds" => 0},
          "worker" => worker
        }
      })

    ws
  end

  defp start_author(task, ws, ctx, branch, wt) do
    # The commit gate (bd-adrym0) wants a valid plan on a UI diff before it routes on; the capture
    # itself is a stub here, so a skip is enough to reach the ReviewGate.
    File.mkdir_p!(Path.join(wt, ".arbiter"))
    File.write!(Path.join(wt, ".arbiter/screenshots.json"), ~s({"version":1,"skip":"test"}))

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
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

    author
  end

  defp start_gate(rig, ctx, opts) do
    _ = ctx

    {:ok, gate} =
      ReviewGate.start(
        [
          author: rig.author,
          task_id: rig.task.id,
          workspace_id: rig.ws.id,
          repo: "trib/repo",
          worktree_path: rig.wt,
          branch: rig.branch,
          target_branch: "main",
          timeout_ms: 15_000,
          rounds: 1,
          pr_ref: nil,
          command: [@probe, "HOLD"]
        ]
        |> Keyword.merge(opts)
      )

    gate
  end

  defp wait_until(fun, timeout \\ 15_000) do
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
