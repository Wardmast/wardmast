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

  # bd-5eegxz: until capture works for a repo, a bad manifest is not worth a fix round.
  describe "route/2: no fix round for a manifest while capture is failing" do
    for {code, detail} <- [manifest_missing: nil, manifest_invalid: ["plan version must be 1"]] do
      test "#{code} proceeds with a note when captures in the workspace are failing" do
        failure = Failure.new(unquote(code), "the manifest problem", detail: unquote(detail))

        assert {:proceed, note} = ScreenshotGate.route({:error, failure}, health: :failing)
        assert note =~ "No screenshots"
        assert note =~ "not the worker"
        refute note =~ "NO-FILE-CHANGE"
      end

      test "#{code} is still sent back when capture works or nothing is known" do
        failure = Failure.new(unquote(code), "the manifest problem", detail: unquote(detail))

        for health <- [:working, :unknown] do
          assert {:send_back, _} = ScreenshotGate.route({:error, failure}, health: health)
        end

        assert {:send_back, _} = ScreenshotGate.route({:error, failure})
      end
    end

    test "a route the manifest names that errors is still the worker's, even while failing" do
      failure = Failure.new(:route_error, "home: GET /nope answered 404 at both", shot: "home")
      assert {:send_back, _} = ScreenshotGate.route({:error, failure}, health: :failing)
    end

    test "skipped and failed captures never route to send_back, whatever the health" do
      outcomes = [
        {:skipped, {:deps_changed, "the change edits mix.lock"}},
        {:skipped, {:no_sandbox, "capture needs a sandbox"}},
        {:error, Failure.new(:boot_failed, "before: no mix.exs", role: "before")},
        {:error, Failure.new(:deps_failed, "nxdomain")}
      ]

      for outcome <- outcomes, health <- [:failing, :working, :unknown] do
        refute match?({:send_back, _}, ScreenshotGate.route(outcome, health: health))
      end
    end

    test "route_reuse passes the health through" do
      failure = Failure.new(:manifest_missing, "none")

      assert {:proceed, _} =
               ScreenshotGate.route_reuse(
                 {:error, failure},
                 %{reason: :unchanged, from: "abc"},
                 "def",
                 health: :failing
               )
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

  # bd-ur1zty: a failed capture never fails a merge (design §2.3). An infrastructure fault is
  # recorded and alerted, and the review runs with a "no screenshots" brief; only a failure the
  # change itself caused (its own app does not boot while the base's did) parks.
  describe "route/2: infrastructure faults let the review proceed" do
    for code <- [:checkout_failed, :diff_failed, :budget_exceeded, :shot_failed, :deps_failed] do
      test "#{code} proceeds with a no-screenshots brief and is never sent back", _ctx do
        failure = Failure.new(unquote(code), "the thing broke", role: "after")

        assert {:proceed, brief} = ScreenshotGate.route({:error, failure})
        assert brief =~ "No screenshots: capture failed: the thing broke"
        assert brief =~ "not the worker"
      end
    end

    test "the offline deps cache failing (the first real capture: DATABASE_URL) proceeds" do
      failure =
        Failure.new(
          :deps_failed,
          "fetching the Mix deps for the capture failed: exit 1: ** (RuntimeError) DATABASE_URL is not set"
        )

      assert {:proceed, brief} = ScreenshotGate.route({:error, failure})
      assert brief =~ "No screenshots: capture failed: fetching the Mix deps"
      assert brief =~ "DATABASE_URL is not set"
    end

    test "the base's own boot failing is the repo's, not the change's: proceeds" do
      failure =
        Failure.new(:boot_failed, "the app failed to boot at the merge-base (start): exit 1",
          role: "before",
          detail: %{phase: :start, output: "exit 1"}
        )

      assert {:proceed, brief} = ScreenshotGate.route({:error, failure})
      assert brief =~ "No screenshots: capture failed:"
    end
  end

  describe "route/2: a failure the change itself caused parks" do
    test "the head's app failing to boot, after the base booted, escalates" do
      failure =
        Failure.new(:boot_failed, "the app failed to boot at the head (start): exit 1",
          role: "after",
          detail: %{phase: :start, output: "exit 1"}
        )

      assert {:escalate, message} = ScreenshotGate.route({:error, failure})
      assert message =~ "failed to boot at the head"
      assert message =~ "the base booted"
    end
  end

  # bd-3glf2a: a capture service that never came up, as `Capture.run/2` records it. Podman and
  # the image are the host's, whichever commit was booting.
  describe "route/2: a service that never became ready" do
    for role <- ["before", "after"] do
      test "at #{role}: proceeds with the service, the reason and its log tail in the brief" do
        failure =
          Failure.new(
            :boot_failed,
            "the app failed to boot at the merge-base (services): service postgres did not " <>
              "become ready in 60 s (last check: exit 2); its log ends:\nFATAL:  could not " <>
              "create lock file",
            role: unquote(role),
            detail: %{
              phase: :services,
              service: "postgres",
              log_tail: "FATAL:  could not create lock file"
            }
          )

        assert {:proceed, brief} = ScreenshotGate.route({:error, failure})
        assert brief =~ "service postgres did not become ready in 60 s"
        assert brief =~ "FATAL:  could not create lock file"
      end
    end
  end

  describe "classify/1" do
    test "tells worker, change and infrastructure faults apart" do
      for code <- [:manifest_missing, :manifest_invalid, :route_error],
          do: assert(ScreenshotGate.classify(Failure.new(code, "m")) == :worker)

      for code <- [:checkout_failed, :diff_failed, :budget_exceeded, :shot_failed, :deps_failed],
          do: assert(ScreenshotGate.classify(Failure.new(code, "m")) == :infrastructure)

      boot = fn role, phase ->
        Failure.new(:boot_failed, "m", role: role, detail: %{phase: phase})
      end

      assert ScreenshotGate.classify(boot.("after", :start)) == :change
      assert ScreenshotGate.classify(boot.("after", :setup)) == :change
      assert ScreenshotGate.classify(boot.("before", :start)) == :infrastructure
      assert ScreenshotGate.classify(boot.("after", :services)) == :infrastructure
      # No detail to tell by: not the change's to answer for.
      assert ScreenshotGate.classify(Failure.new(:boot_failed, "m", role: "after")) ==
               :infrastructure
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

  describe "plan/3: the capture lifecycle (bd-8qj1sa)" do
    @ui_block %{"ui_paths" => ["web/**"], "start_cmd" => "true"}

    defp git!(dir, args),
      do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

    defp commit!(dir, file, body) do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
      git!(dir, ["add", "-A"])
      git!(dir, ["-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "-q", "-m", body])
      {sha, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"])
      String.trim(sha)
    end

    # base → h1 (touches web/) → h2 (docs only) → h3 (touches web/)
    defp history_repo(tmp) do
      git!(tmp, ["init", "-q", "-b", "main"])
      base = commit!(tmp, "README.md", "seed")
      h1 = commit!(tmp, "web/a.txt", "one")
      h2 = commit!(tmp, "docs/x.md", "two")
      h3 = commit!(tmp, "web/a.txt", "three")
      %{base: base, h1: h1, h2: h2, h3: h3}
    end

    defp checked(head, plan_hash \\ nil) do
      %{
        head_sha: head,
        plan_hash: plan_hash,
        outcome: {:ok, %{pairs: [], head_sha: head, notes: nil}}
      }
    end

    defp hist(attempts, last_head, plan_hash \\ nil) do
      %{
        attempts: attempts,
        last_captured: last_head && %{head_sha: last_head, plan_hash: plan_hash}
      }
    end

    test "re-capture is skipped when the diff since the last captured head misses ui_paths",
         %{tmp_dir: tmp} do
      r = history_repo(tmp)

      st =
        state(tmp, %{
          base_sha: r.base,
          head_sha: r.h2,
          screenshot_checked: checked(r.h1)
        })

      assert {:reuse, {:ok, _} = outcome, %{reason: :unchanged, from: from}} =
               ScreenshotGate.plan(st, workspace(@ui_block), hist(1, r.h1))

      assert from == r.h1

      assert {:proceed, ctx} =
               ScreenshotGate.route_reuse(outcome, %{reason: :unchanged, from: from}, r.h2)

      assert ctx =~ String.slice(r.h1, 0, 12)
      assert ctx =~ "not retaken"
    end

    test "re-capture runs when the diff since the last captured head touches ui_paths",
         %{tmp_dir: tmp} do
      r = history_repo(tmp)

      st =
        state(tmp, %{base_sha: r.base, head_sha: r.h3, screenshot_checked: checked(r.h1)})

      assert {:run, _job} = ScreenshotGate.plan(st, workspace(@ui_block), hist(1, r.h1))
    end

    test "re-capture runs when the plan changed even though the diff misses ui_paths",
         %{tmp_dir: tmp} do
      r = history_repo(tmp)
      plan = Path.join(tmp, ".arbiter/screenshots.json")
      File.mkdir_p!(Path.dirname(plan))
      File.write!(plan, ~s({"version":1,"skip":"changed"}))

      st =
        state(tmp, %{
          base_sha: r.base,
          head_sha: r.h2,
          screenshot_checked: checked(r.h1, "oldhash")
        })

      assert {:run, _job} =
               ScreenshotGate.plan(st, workspace(@ui_block), hist(1, r.h1, "oldhash"))
    end

    test "with no in-memory outcome to reuse (a restarted gate) it captures", %{tmp_dir: tmp} do
      r = history_repo(tmp)
      st = state(tmp, %{base_sha: r.base, head_sha: r.h2})
      assert {:run, _job} = ScreenshotGate.plan(st, workspace(@ui_block), hist(1, r.h1))
    end

    # bd-3glf2a: the gate always passes a history, so this is the path every production capture
    # takes; its job must name the branch whose mix.lock the offline deps cache trusts.
    test "a capture the lifecycle runs carries the default branch the deps cache trusts",
         %{tmp_dir: tmp} do
      r = history_repo(tmp)
      st = state(tmp, %{base_sha: r.base, head_sha: r.h3, screenshot_checked: checked(r.h1)})
      develop = put_in(workspace(@ui_block), [:config, "merge"], %{"base" => "develop"})

      assert {:run, job} = ScreenshotGate.plan(st, develop, hist(1, r.h1))
      assert job.input.default_branch == "develop"

      assert {:run, job} = ScreenshotGate.plan(st, workspace(@ui_block), hist(1, r.h1))
      assert job.input.default_branch == "main"
    end

    test "max_captures_per_ticket is enforced: at the cap the last set is reused", %{tmp_dir: tmp} do
      r = history_repo(tmp)
      st = state(tmp, %{base_sha: r.base, head_sha: r.h3, screenshot_checked: checked(r.h1)})

      assert {:reuse, {:ok, _}, %{reason: :cap, from: from, max: 3}} =
               ScreenshotGate.plan(st, workspace(@ui_block), hist(3, r.h1))

      assert from == r.h1
    end

    test "max_captures_per_ticket is enforced: at the cap with nothing captured, it is a skip",
         %{tmp_dir: tmp} do
      r = history_repo(tmp)
      st = state(tmp, %{base_sha: r.base, head_sha: r.h3})

      assert {:cached, {:skipped, {:cap_reached, 3}} = outcome} =
               ScreenshotGate.plan(st, workspace(@ui_block), hist(3, nil))

      assert {:proceed, ctx} = ScreenshotGate.route(outcome)
      assert ctx =~ "max_captures_per_ticket"
    end

    test "the configured cap is read from limits", %{tmp_dir: tmp} do
      r = history_repo(tmp)
      block = Map.put(@ui_block, "limits", %{"max_captures_per_ticket" => 1})
      st = state(tmp, %{base_sha: r.base, head_sha: r.h3})

      assert {:cached, {:skipped, {:cap_reached, 1}}} =
               ScreenshotGate.plan(st, workspace(block), hist(1, nil))
    end

    test "a head already checked still wins over the cap", %{tmp_dir: tmp} do
      r = history_repo(tmp)
      c = checked(r.h3)
      st = state(tmp, %{base_sha: r.base, head_sha: r.h3, screenshot_checked: c})
      assert ScreenshotGate.plan(st, workspace(@ui_block), hist(5, r.h3)) == {:cached, c.outcome}
    end
  end
end
