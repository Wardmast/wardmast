defmodule Wardmast.Worker.ReviewGate.ScreenshotGateTest do
  @moduledoc """
  The ReviewGate's screenshot step (bd-84latk, GitHub #1328): a UI change must reach the reviewer
  with its screenshots, go back to the worker when the worker gave no manifest, and escalate
  (never loop the worker) when capture failed for an infrastructure reason.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Worker.ReviewGate.ScreenshotGate

  @moduletag :tmp_dir

  defp workspace(screenshots) do
    worker =
      case screenshots do
        nil -> %{}
        block -> %{"repos" => %{"trib/repo" => %{"screenshots" => block}}}
      end

    %{config: %{"worker" => worker}}
  end

  defp state(tmp_dir, extra \\ %{}) do
    Map.merge(
      %{
        task_id: "bd-test",
        repo: "trib/repo",
        worktree_path: tmp_dir,
        base_sha: "b" <> String.duplicate("0", 39),
        head_sha: "a" <> String.duplicate("1", 39),
        screenshot_checked: nil
      },
      extra
    )
  end

  @block %{"ui_paths" => ["web/**"], "start_cmd" => "true"}

  describe "plan/2" do
    test "a repo with no screenshots config is not checked at all", %{tmp_dir: tmp} do
      assert ScreenshotGate.plan(state(tmp), workspace(nil)) == :skip
      assert ScreenshotGate.plan(state(tmp), nil) == :skip
    end

    test "a gate with no worktree has nothing to capture from", %{tmp_dir: tmp} do
      assert ScreenshotGate.plan(state(tmp, %{worktree_path: nil}), workspace(@block)) == :skip
    end

    test "a configured repo yields a capture job reading the worktree's own manifest",
         %{tmp_dir: tmp} do
      assert {:run, job} = ScreenshotGate.plan(state(tmp), workspace(@block))
      assert job.input.task_id == "bd-test"
      assert job.input.repo_path == tmp
      assert job.input.plan_path == Path.join([tmp, ".arbiter", "screenshots.json"])
      assert job.input.head_sha == "a" <> String.duplicate("1", 39)
      # bd-3glf2a: the deps cache's trusted lockfile comes from the default branch.
      assert job.input.default_branch == "main"
    end

    test "the default branch is the workspace's merge base for the repo", %{tmp_dir: tmp} do
      ws = workspace(@block)
      ws = put_in(ws, [:config, "merge"], %{"base" => "develop"})
      assert {:run, job} = ScreenshotGate.plan(state(tmp), ws)
      assert job.input.default_branch == "develop"
    end

    test "the plan the commit gate stored feeds the capture instead of the live file",
         %{tmp_dir: tmp} do
      root = Path.join(tmp, "plans")
      body = ~s({"version":1,"skip":"x"})

      :ok =
        Wardmast.Screenshots.PlanCheck.store(root, "bd-test", %{
          sha: Wardmast.Screenshots.PlanCheck.sha(body),
          body: body
        })

      assert {:run, job} =
               ScreenshotGate.plan(state(tmp, %{screenshot_plan_root: root}), workspace(@block))

      assert job.input.plan_path == Wardmast.Screenshots.PlanCheck.stored_path(root, "bd-test")
    end

    test "a head already checked is not captured again", %{tmp_dir: tmp} do
      head = "a" <> String.duplicate("1", 39)
      checked = %{head_sha: head, outcome: {:skipped, :no_ui_paths}}
      st = state(tmp, %{screenshot_checked: checked})

      assert ScreenshotGate.plan(st, workspace(@block)) == {:cached, checked.outcome}
    end

    test "a config block that does not validate leaves today's behaviour", %{tmp_dir: tmp} do
      assert ScreenshotGate.plan(state(tmp), workspace(%{"ui_paths" => "nope"})) == :skip
    end
  end

  describe "route/2: screenshots reach the reviewer" do
    test "captured pairs go into the reviewer's context", %{tmp_dir: tmp} do
      before_png = Path.join(tmp, "home__desktop-light__before.png")
      after_png = Path.join(tmp, "home__desktop-light__after.png")
      File.write!(before_png, "png")
      File.write!(after_png, "png")

      result = %{
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
          },
          %{
            id: "new",
            title: "New",
            viewport: "desktop",
            theme: "light",
            label: "New · desktop · light",
            kind: :new,
            before: %{status: :absent, reason: "new at this commit"},
            after: %{status: :ok, file: after_png, name: "a.png", sha256: "y", bytes: 3}
          }
        ],
        notes: "the modal is behind the second button"
      }

      assert {:proceed, context} = ScreenshotGate.route({:ok, result})
      assert context =~ "Home · desktop · light"
      assert context =~ before_png
      assert context =~ after_png
      assert context =~ "new at this commit"
      assert context =~ "the modal is behind the second button"
    end

    test "a worker's declared skip reaches the reviewer with its reason" do
      assert {:proceed, context} =
               ScreenshotGate.route({:skipped, {:plan_skip, "copy change only"}})

      assert context =~ "copy change only"
      assert context =~ "skip"
    end

    test "a change outside ui_paths proceeds with no screenshot context" do
      assert ScreenshotGate.route({:skipped, :no_ui_paths}) == {:proceed, nil}
    end

    test "a host that cannot sandbox the capture proceeds, telling the reviewer why there are none" do
      reason = "capture needs a sandbox: bubblewrap (bwrap) is not installed"

      assert {:proceed, context} = ScreenshotGate.route({:skipped, {:no_sandbox, reason}})
      assert context =~ reason
      assert context =~ "No screenshots were taken"
      # the worker did nothing wrong, so the reviewer must not hold it against them
      assert context =~ "not the worker"
    end
  end

  # bd-3glf2a: the offline deps cache only trusts a default-branch lockfile.
  describe "route/2: a change that edits mix.lock (deps_changed)" do
    test "proceeds, telling the reviewer why there are no screenshots and that it is expected" do
      reason = "the change edits mix.lock; a capture boot has no network"

      assert {:proceed, context} = ScreenshotGate.route({:skipped, {:deps_changed, reason}})
      assert context =~ "No screenshots were taken"
      assert context =~ reason
      assert context =~ "mix.lock"
      refute context =~ "lazy"
    end
  end

  describe "route/2: worker faults go back to the worker" do
    test "no manifest is sent back with the instruction to add one" do
      failure = Failure.new(:manifest_missing, "the worker wrote no screenshots manifest")

      assert {:send_back, findings} = ScreenshotGate.route({:error, failure})
      assert findings =~ ".arbiter/screenshots.json"
      assert findings =~ "NO-FILE-CHANGE:"
      assert findings =~ ~s("skip")
    end

    test "an invalid manifest is sent back with the validation errors" do
      failure =
        Failure.new(:manifest_invalid, "invalid", detail: ["shots[0].path must start with /"])

      assert {:send_back, findings} = ScreenshotGate.route({:error, failure})
      assert findings =~ "shots[0].path must start with /"
    end

    test "a route the manifest names that errors is the worker's to fix" do
      failure =
        Failure.new(:route_error, "home: GET /nope answered 404 at both", shot: "home")

      assert {:send_back, findings} = ScreenshotGate.route({:error, failure})
      assert findings =~ "GET /nope"
    end
  end

  describe "route/2: infrastructure faults escalate" do
    for code <- [:boot_failed, :checkout_failed, :diff_failed, :budget_exceeded, :shot_failed] do
      test "#{code} escalates and is never sent back", _ctx do
        failure = Failure.new(unquote(code), "the thing broke", role: "after")

        assert {:escalate, message} = ScreenshotGate.route({:error, failure})
        assert message =~ "the thing broke"
        assert message =~ "not the worker"
      end
    end
  end

  # bd-3glf2a: a capture service that never came up, as `Capture.run/2` records it.
  describe "route/2: a service that never became ready" do
    test "escalates with the service, the reason and its log tail in the brief" do
      failure =
        Failure.new(
          :boot_failed,
          "the app failed to boot at the merge-base (services): service postgres did not " <>
            "become ready in 60 s (last check: exit 2); its log ends:\nFATAL:  could not " <>
            "create lock file",
          role: "before",
          detail: %{
            phase: :services,
            service: "postgres",
            log_tail: "FATAL:  could not create lock file"
          }
        )

      assert {:escalate, message} = ScreenshotGate.route({:error, failure})
      assert message =~ "service postgres did not become ready in 60 s"
      assert message =~ "FATAL:  could not create lock file"
      assert message =~ "not the worker"
    end
  end

  describe "classify/1" do
    test "tells worker faults from infrastructure faults" do
      for code <- [:manifest_missing, :manifest_invalid, :route_error],
          do: assert(ScreenshotGate.classify(Failure.new(code, "m")) == :worker)

      for code <- [:boot_failed, :checkout_failed, :diff_failed, :budget_exceeded, :shot_failed],
          do: assert(ScreenshotGate.classify(Failure.new(code, "m")) == :infrastructure)
    end
  end

  describe "run/2" do
    test "an exception in capture is an infrastructure failure, not a crash", %{tmp_dir: tmp} do
      {:run, job} = ScreenshotGate.plan(state(tmp), workspace(@block))
      outcome = ScreenshotGate.run(job, fn _input, _opts -> raise "no chromium" end)

      assert {:error, %Failure{code: :shot_failed, message: message}} = outcome
      assert message =~ "no chromium"
    end

    test "passes the capture's own result through", %{tmp_dir: tmp} do
      {:run, job} = ScreenshotGate.plan(state(tmp), workspace(@block))

      assert ScreenshotGate.run(job, fn _i, _o -> {:skipped, :no_ui_paths} end) ==
               {:skipped, :no_ui_paths}
    end
  end

  describe "reviewer_block/1" do
    test "is empty when there is no context" do
      assert ScreenshotGate.reviewer_block(nil) == ""
    end
  end
end
