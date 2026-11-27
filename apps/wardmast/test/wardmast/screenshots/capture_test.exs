defmodule Wardmast.Screenshots.CaptureTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CaptureHostSandbox
  alias Wardmast.Test.CaptureNoSandbox
  alias Wardmast.Test.CaptureStubBooter
  alias Wardmast.Test.CaptureStubShooter

  @moduletag :tmp_dir

  @config %Config{ui_paths: ["web/**"], start_cmd: "true"}

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  # base: web/page.txt "v1"; head: web/page.txt "v2" (or README only when ui? is false).
  defp repo!(dir, ui?) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "web"))
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "web/page.txt"), "v1")
    File.write!(Path.join(repo, "README.md"), "r1")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])

    if ui?,
      do: File.write!(Path.join(repo, "web/page.txt"), "v2"),
      else: File.write!(Path.join(repo, "README.md"), "r2")

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "head"])
    {repo, base, git!(repo, ["rev-parse", "HEAD"])}
  end

  defp write_plan!(dir, shots, extra \\ %{}) do
    path = Path.join(dir, "screenshots.json")
    File.write!(path, Jason.encode!(Map.merge(%{"version" => 1, "shots" => shots}, extra)))
    path
  end

  defp run(dir, plan_path, ctx_extra \\ %{}, opts \\ []) do
    {repo, base, head} = Process.get(:repo)
    {config, opts} = Keyword.pop(opts, :config, @config)

    ctx =
      Map.merge(
        %{test_pid: self(), routes: %{"before" => %{"/" => 200}, "after" => %{"/" => 200}}},
        ctx_extra
      )

    Capture.run(
      %{
        task_id: "bd-test",
        repo_path: repo,
        base_sha: base,
        head_sha: head,
        config: config,
        plan_path: plan_path,
        out_dir: Path.join(dir, "out")
      },
      Keyword.merge(
        [
          booter: CaptureStubBooter,
          shooter: CaptureStubShooter,
          sandbox: CaptureHostSandbox,
          ctx: ctx
        ],
        opts
      )
    )
  end

  setup %{tmp_dir: dir} do
    Process.put(:repo, repo!(dir, true))
    :ok
  end

  test "produces a before/after pair for every declared entry", %{tmp_dir: dir} do
    plan =
      write_plan!(dir, [
        %{
          "id" => "home",
          "path" => "/",
          "viewports" => ["desktop", "mobile"],
          "themes" => ["light", "dark"]
        }
      ])

    assert {:ok, result} = run(dir, plan)
    assert length(result.pairs) == 4
    assert Enum.all?(result.pairs, &(&1.kind == :changed))

    for pair <- result.pairs do
      assert File.read!(pair.before.file) == "png:before:/"
      assert File.read!(pair.after.file) == "png:after:/"
      assert pair.before.sha256 =~ ~r/\A[0-9a-f]{64}\z/
      assert pair.before.bytes == byte_size("png:before:/")
    end

    # every file name is distinct
    files = Enum.flat_map(result.pairs, &[&1.before.file, &1.after.file])
    assert length(Enum.uniq(files)) == 8
  end

  test "boots and stops the base app before the head app, from their own source trees", %{
    tmp_dir: dir
  } do
    plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
    assert {:ok, _} = run(dir, plan)

    {:messages, msgs} = Process.info(self(), :messages)

    lifecycle =
      for msg <- msgs, elem(msg, 0) in [:boot, :stop], do: {elem(msg, 0), elem(msg, 1)}

    assert lifecycle == [boot: "before", stop: "before", boot: "after", stop: "after"]

    assert_received {:tree, "before", "v1"}
    assert_received {:tree, "after", "v2"}
  end

  test "a new route is after-only and a removed route is before-only", %{tmp_dir: dir} do
    plan =
      write_plan!(dir, [
        %{"id" => "kept", "path" => "/"},
        %{"id" => "fresh", "path" => "/new"},
        %{"id" => "gone", "path" => "/old"}
      ])

    routes = %{
      "before" => %{"/" => 200, "/old" => 200},
      "after" => %{"/" => 200, "/new" => 200}
    }

    assert {:ok, result} = run(dir, plan, %{routes: routes})
    by_id = Map.new(result.pairs, &{&1.id, &1})

    assert by_id["kept"].kind == :changed

    assert by_id["fresh"].kind == :new
    assert %{status: :absent} = by_id["fresh"].before
    assert File.exists?(by_id["fresh"].after.file)

    assert by_id["gone"].kind == :removed
    assert %{status: :absent} = by_id["gone"].after
    assert File.exists?(by_id["gone"].before.file)
  end

  test "before_path is the path used at the base commit", %{tmp_dir: dir} do
    plan = write_plan!(dir, [%{"id" => "moved", "path" => "/p", "before_path" => "/patient"}])
    routes = %{"before" => %{"/patient" => 200}, "after" => %{"/p" => 200}}

    assert {:ok, %{pairs: [pair]}} = run(dir, plan, %{routes: routes})
    assert pair.kind == :changed
    assert File.read!(pair.before.file) == "png:before:/patient"
    assert File.read!(pair.after.file) == "png:after:/p"
  end

  test "entries needing different seeds boot separately", %{tmp_dir: dir} do
    config = %{@config | seeds: %{"empty" => "true"}}

    plan =
      write_plan!(dir, [
        %{"id" => "a", "path" => "/"},
        %{"id" => "b", "path" => "/", "seed" => "empty"}
      ])

    {repo, base, head} = Process.get(:repo)

    ctx = %{test_pid: self(), routes: %{"before" => %{"/" => 200}, "after" => %{"/" => 200}}}

    assert {:ok, %{pairs: pairs}} =
             Capture.run(
               %{
                 task_id: "t",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 config: config,
                 plan_path: plan,
                 out_dir: Path.join(dir, "out")
               },
               booter: CaptureStubBooter,
               shooter: CaptureStubShooter,
               sandbox: CaptureHostSandbox,
               ctx: ctx
             )

    assert length(pairs) == 2

    for role <- ["before", "after"],
        seed <- [nil, "empty"],
        do: assert_received({:boot, ^role, ^seed, _})
  end

  test "plan_required false with default_routes shoots the routes when there is no plan",
       %{tmp_dir: dir} do
    {repo, base, head} = Process.get(:repo)

    config = %Config{
      ui_paths: ["web/**"],
      start_cmd: "true",
      plan_required: false,
      default_routes: ["/"]
    }

    ctx = %{test_pid: self(), routes: %{"before" => %{"/" => 200}, "after" => %{"/" => 200}}}

    assert {:ok, %{pairs: [_ | _]}} =
             Capture.run(
               %{
                 task_id: "bd-test",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 config: config,
                 plan_path: Path.join(dir, "nope.json"),
                 out_dir: Path.join(dir, "out")
               },
               booter: CaptureStubBooter,
               sandbox: CaptureHostSandbox,
               shooter: CaptureStubShooter,
               ctx: ctx
             )
  end

  defmodule PathDeps do
    def prepare(_input, _opts), do: {:ok, nil}
  end

  test "pinned PATH entries the filter dropped are named in the result and capture.json",
       %{tmp_dir: dir} do
    config = %Config{
      ui_paths: ["web/**"],
      start_cmd: "true",
      env: %{"PATH" => "/opt/ok/bin:/home/nobody/mise/bin"},
      deps: %{"mix" => true}
    }

    plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
    {repo, base, head} = Process.get(:repo)

    assert {:ok, result} =
             Capture.run(
               %{
                 task_id: "bd-test",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 config: config,
                 plan_path: plan,
                 out_dir: Path.join(dir, "out")
               },
               booter: CaptureStubBooter,
               shooter: CaptureStubShooter,
               sandbox: CaptureHostSandbox,
               deps: PathDeps,
               ctx: %{
                 test_pid: self(),
                 routes: %{"before" => %{"/" => 200}, "after" => %{"/" => 200}}
               }
             )

    assert result.notes =~ "/home/nobody/mise/bin"
    refute result.notes =~ "/opt/ok/bin"
    assert File.read!(result.manifest_path) =~ "/home/nobody/mise/bin"
  end

  describe "failures are distinct and recorded" do
    test "a missing manifest", %{tmp_dir: dir} do
      assert {:error, failure} = run(dir, Path.join(dir, "nope.json"))
      assert failure.code == :manifest_missing
      assert failure.message =~ "screenshots"
      refute_received {:boot, _, _, _}
      assert recorded(dir)["state"] == "failed"
      assert recorded(dir)["failure"]["code"] == "manifest_missing"
    end

    test "an invalid manifest", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, ~s({"version": 9}))
      assert {:error, failure} = run(dir, path)
      assert failure.code == :manifest_invalid
      assert failure.detail != []
      refute_received {:boot, _, _, _}
      assert recorded(dir)["failure"]["code"] == "manifest_invalid"
    end

    test "the base app failing to boot", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:error, failure} = run(dir, plan, %{boot_failures: %{"before" => "exit 1"}})
      assert failure.code == :boot_failed
      assert failure.role == "before"
      assert failure.message =~ "exit 1"
      refute_received {:boot, "after", _, _}
      assert recorded(dir)["failure"]["code"] == "boot_failed"
      assert recorded(dir)["failure"]["role"] == "before"
    end

    test "the head app failing to boot", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:error, failure} = run(dir, plan, %{boot_failures: %{"after" => "port in use"}})
      assert failure.code == :boot_failed
      assert failure.role == "after"
      assert_received {:boot, "before", _, _}
    end

    test "a route returning an error at the head", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      routes = %{"before" => %{"/" => 200}, "after" => %{"/" => 500}}
      assert {:error, failure} = run(dir, plan, %{routes: routes})
      assert failure.code == :route_error
      assert failure.role == "after"
      assert failure.shot == "home"
      assert failure.message =~ "500"
      assert_received {:stop, "after", nil}
      assert recorded(dir)["failure"]["code"] == "route_error"
      assert recorded(dir)["failure"]["shot"] == "home"
    end

    test "a route returning an error at the base fails before the head is booted", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      routes = %{"before" => %{"/" => 503}, "after" => %{"/" => 200}}
      assert {:error, %{code: :route_error, role: "before"}} = run(dir, plan, %{routes: routes})
      refute_received {:boot, "after", _, _}
    end

    test "a route missing at both commits is a route error, not a new route", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "ghost", "path" => "/ghost"}])
      assert {:error, %{code: :route_error, shot: "ghost"}} = run(dir, plan)
    end

    test "a shooter failure other than an HTTP status is its own reason", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, failure} =
               run(dir, plan, %{shoot_error: {:shot, "selector #edit not found"}})

      assert failure.code == :shot_failed
      assert failure.message =~ "#edit"
    end

    test "a shot failure records the tail of the app's server output for that side", %{
      tmp_dir: dir
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      ctx = %{
        shoot_error: {:shot, "page.goto: net::ERR_EMPTY_RESPONSE"},
        server_logs: %{"before" => "BEFORE-LOG\n** (RuntimeError) boom"}
      }

      assert {:error, failure} = run(dir, plan, ctx)
      assert failure.code == :shot_failed
      assert failure.server_log =~ "BEFORE-LOG"
      assert recorded(dir)["failure"]["server_log"] =~ "(RuntimeError) boom"
    end

    test "readiness is re-checked right before a side's first navigation", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:ok, _} = run(dir, plan)
      assert_received {:ready_check, "before"}
      assert_received {:ready_check, "after"}
    end

    test "an app that stopped answering is 'app not ready', distinct from a page error", %{
      tmp_dir: dir
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      ctx = %{
        not_ready: %{"after" => "GET /sign-in: connection closed"},
        server_logs: %{"after" => "AFTER-CRASH-LOG"}
      }

      assert {:error, failure} = run(dir, plan, ctx)
      assert failure.code == :app_not_ready
      assert failure.role == "after"
      assert failure.message =~ "not ready"
      assert failure.server_log =~ "AFTER-CRASH-LOG"
      refute_received {:shoot, "after", _, _, _}
      assert recorded(dir)["failure"]["code"] == "app_not_ready"
      assert recorded(dir)["failure"]["server_log"] =~ "AFTER-CRASH-LOG"
    end

    test "the app is stopped even when the shooter crashes", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :shot_failed}} =
               run(dir, plan, %{shoot_raise: "chromium fell over"})

      assert_received {:stop, "before", nil}
    end

    test "the record callback receives the failure", %{tmp_dir: dir} do
      test_pid = self()

      assert {:error, _} =
               run(dir, Path.join(dir, "nope.json"), %{},
                 record: &send(test_pid, {:recorded, &1})
               )

      assert_received {:recorded, %{state: :failed, failure: %{code: :manifest_missing}}}
    end

    test "an exhausted budget stops before booting", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:error, %{code: :budget_exceeded}} = run(dir, plan, %{}, budget_seconds: 0)
      refute_received {:boot, _, _, _}
    end
  end

  describe "when the diff does not touch ui_paths" do
    test "nothing runs: no manifest read, no boot, no output", %{tmp_dir: dir} do
      Process.put(:repo, repo!(Path.join(dir, "docs-only") |> tap(&File.mkdir_p!/1), false))
      assert {:skipped, :no_ui_paths} = run(dir, Path.join(dir, "nope.json"))
      refute_received {:boot, _, _, _}
      refute_received {:shoot, _, _, _, _}
      refute File.exists?(Path.join(dir, "out"))
    end
  end

  describe "when this host cannot sandbox the capture (bd-bhrsdv)" do
    test "it is skipped with 'capture needs a sandbox' before anything is read or booted", %{
      tmp_dir: dir
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      parent = self()

      assert {:skipped, {:no_sandbox, reason}} =
               run(dir, plan, %{},
                 sandbox: CaptureNoSandbox,
                 record: fn event -> send(parent, {:event, event}) end
               )

      assert reason =~ "capture needs a sandbox"
      assert reason =~ "this test host has no sandbox"
      refute_received {:boot, _, _, _}
      refute_received {:shoot, _, _, _, _}
      assert_received {:event, %{state: :skipped, kind: :no_sandbox, reason: ^reason}}

      manifest = recorded(dir)
      assert manifest["state"] == "skipped"
      assert manifest["skip_kind"] == "no_sandbox"
      assert manifest["skip"] == reason
    end

    test "a missing manifest is not the worker's fault then: nothing could be captured", %{
      tmp_dir: dir
    } do
      assert {:skipped, {:no_sandbox, _}} =
               run(dir, Path.join(dir, "nope.json"), %{}, sandbox: CaptureNoSandbox)
    end

    test "the default sandbox is bwrap, and where it is unavailable the capture skips", %{
      tmp_dir: dir
    } do
      # config/test.exs turns the bwrap sandbox off (`:capture_sandbox_available` false), the
      # answer every host without bwrap gets.
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      {repo, base, head} = Process.get(:repo)

      assert {:skipped, {:no_sandbox, reason}} =
               Capture.run(
                 %{
                   task_id: "t",
                   repo_path: repo,
                   base_sha: base,
                   head_sha: head,
                   config: @config,
                   plan_path: plan,
                   out_dir: Path.join(dir, "out")
                 },
                 booter: CaptureStubBooter,
                 shooter: CaptureStubShooter,
                 ctx: %{test_pid: self(), routes: %{}}
               )

      assert reason =~ "capture needs a sandbox"
      refute_received {:boot, _, _, _}
    end
  end

  test "the booter and the shooter run under the capture's sandbox; each shot has its own dir", %{
    tmp_dir: dir
  } do
    plan =
      write_plan!(dir, [%{"id" => "home", "path" => "/", "viewports" => ["desktop", "mobile"]}])

    assert {:ok, _result} = run(dir, plan)

    assert_received {:boot_sandbox, "before", CaptureHostSandbox}
    assert_received {:boot_sandbox, "after", CaptureHostSandbox}

    {:messages, msgs} = Process.info(self(), :messages)

    shots =
      for {:shot_env, role, sandbox, app, scratch, dir?} <- msgs,
          do: {role, sandbox, app, scratch, dir?}

    assert length(shots) == 4

    images = Path.join([dir, "out", "images"])

    for {role, sandbox, app, scratch, dir?} <- shots do
      assert sandbox == CaptureHostSandbox
      # the boot's own handle on the app, handed on so the browser can reach it
      assert app == %{port: 1, role: role}
      # a fresh directory per shot, outside the images the other shots wrote
      assert dir?
      refute String.starts_with?(scratch, images)
    end

    assert shots |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> length() == 4
  end

  test "a plan that skips is reported as skipped, with its reason", %{tmp_dir: dir} do
    path = Path.join(dir, "skip.json")
    File.write!(path, ~s({"version":1,"skip":"copy-only change"}))
    assert {:skipped, {:plan_skip, "copy-only change"}} = run(dir, path)
    refute_received {:boot, _, _, _}
  end

  test "poster_pairs/1 hands the pairs to the poster shape", %{tmp_dir: dir} do
    plan =
      write_plan!(dir, [
        %{"id" => "kept", "title" => "Kept", "path" => "/"},
        %{"id" => "fresh", "path" => "/new"}
      ])

    routes = %{"before" => %{"/" => 200}, "after" => %{"/" => 200, "/new" => 200}}
    assert {:ok, result} = run(dir, plan, %{routes: routes})

    assert [kept, fresh] = Capture.poster_pairs(result)
    assert kept.label == "Kept · desktop · light"
    assert %{name: _, data: "png:before:/"} = kept.before
    assert %{data: "png:after:/"} = kept.after
    assert {:text, "new at this commit"} = fresh.before
    assert %{data: "png:after:/new"} = fresh.after
  end

  test "the manifest of a successful capture is recorded", %{tmp_dir: dir} do
    plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
    assert {:ok, _} = run(dir, plan)
    manifest = recorded(dir)
    assert manifest["state"] == "ok"
    assert manifest["head_sha"] =~ ~r/\A[0-9a-f]{40}\z/
    assert [%{"id" => "home", "kind" => "changed"}] = manifest["shots"]
    assert Enum.map(manifest["boots"], & &1["role"]) == ["before", "after"]
  end

  describe "capture.json records a reason (bd-5eegxz)" do
    test "a failed capture has a top-level reason: the failure's message", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:error, failure} = run(dir, plan, %{boot_failures: %{"before" => "exit 1"}})
      manifest = recorded(dir)
      assert manifest["state"] == "failed"
      assert manifest["reason"] == failure.message
      assert manifest["reason"] != ""
    end

    test "a skipped capture has a top-level reason", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:skipped, {:no_sandbox, reason}} = run(dir, plan, %{}, sandbox: CaptureNoSandbox)
      manifest = recorded(dir)
      assert manifest["state"] == "skipped"
      assert manifest["reason"] == reason
      assert manifest["reason"] != ""
    end

    test "a plan skip is recorded with its reason too", %{tmp_dir: dir} do
      plan = Path.join(dir, "skip.json")
      File.write!(plan, ~s({"version": 1, "skip": "copy only"}))
      assert {:skipped, {:plan_skip, "copy only"}} = run(dir, plan)
      assert recorded(dir)["reason"] == "copy only"
    end
  end

  describe "the before/after checkouts are idempotent (bd-5eegxz)" do
    defp read_only_tree!(path) do
      File.mkdir_p!(Path.join(path, "deps/pkg"))
      File.write!(Path.join(path, "deps/pkg/mod.ex"), "old")
      File.write!(Path.join(path, "stale.txt"), "left by a dead attempt")
      {_, 0} = System.cmd("chmod", ["-R", "a-w", path])
      on_exit(fn -> System.cmd("chmod", ["-R", "u+w", path], stderr_to_stdout: true) end)
    end

    test "a work dir an earlier attempt left cannot leak into, or fail, the next boot", %{
      tmp_dir: dir
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      # Exactly where the old code kept it: out/work/<role>/{checkout,scratch-default}.
      for role <- ["before", "after"] do
        old = Path.join([dir, "out", "work", role])
        read_only_tree!(Path.join(old, "checkout"))
        read_only_tree!(Path.join(old, "scratch-default"))
      end

      assert {:ok, _} = run(dir, plan)
      assert_received {:checkout_entries, "before", before_entries}
      assert_received {:checkout_entries, "after", after_entries}
      refute "stale.txt" in before_entries
      refute "stale.txt" in after_entries
      assert "web" in before_entries
      assert recorded(dir)["state"] == "ok"
    end

    test "a stale attempt directory (a killed run's) is swept, a recent one is left", %{
      tmp_dir: dir
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      work = Path.join([dir, "out", "work"])
      old = Path.join(work, "deadbeef00")
      recent = Path.join(work, "alive00000")
      read_only_tree!(Path.join(old, "before"))
      File.mkdir_p!(recent)
      File.touch!(old, System.os_time(:second) - 86_400)

      assert {:ok, _} = run(dir, plan)
      refute File.exists?(old)
      assert File.dir?(recent)
    end
  end

  describe "data safety: the DOM text scan (bd-995svb)" do
    import ExUnit.CaptureLog

    alias Wardmast.Screenshots.Section
    alias Wardmast.Worker.ReviewGate.ScreenshotGate

    @leak "jo.customer@acme-corp.io"

    defp page_plan(dir), do: write_plan!(dir, [%{"id" => "home", "path" => "/"}])

    test "a shot whose text leaks is withheld: no image, the rule is all that is recorded", %{
      tmp_dir: dir
    } do
      plan = page_plan(dir)

      log =
        capture_log(fn ->
          send(self(), {:result, run(dir, plan, %{dom_text: ["Welcome", "Mail #{@leak}"]})})
        end)

      assert_received {:result, {:ok, result}}
      [pair] = result.pairs
      assert %{status: :withheld, rule: "email-domain"} = pair.after
      assert %{status: :withheld, rule: "email-domain"} = pair.before
      refute File.exists?(Path.join([dir, "out", "images", "home__desktop-light__after.png"]))
      refute File.exists?(Path.join([dir, "out", "images", "home__desktop-light__before.png"]))

      shot = recorded(dir)["shots"] |> hd()
      assert shot["after"] == %{"status" => "withheld", "rule" => "email-domain"}

      # the matched text is nowhere: log, capture.json, the PR body, the reviewer brief
      capture_json = File.read!(Path.join([dir, "out", "capture.json"]))

      pr_body =
        result |> Capture.poster_pairs() |> Enum.map(&poster_row/1) |> Section.render()

      assert pr_body =~ "withheld by the data-safety scan: email-domain"
      {:proceed, brief} = ScreenshotGate.route({:ok, result})
      assert brief =~ "withheld by the data-safety scan: email-domain"

      for surface <- [log, capture_json, pr_body, brief, inspect(result)] do
        refute surface =~ "acme-corp"
        refute surface =~ "jo.customer"
      end
    end

    test "only the image that leaked is withheld", %{tmp_dir: dir} do
      plan = page_plan(dir)
      ctx = %{dom_text: %{"before" => ["fine"], "after" => ["Mail #{@leak}"]}}

      assert {:ok, %{pairs: [pair]}} = run(dir, plan, ctx)
      assert %{status: :ok} = pair.before
      assert %{status: :withheld, rule: "email-domain"} = pair.after
    end

    test "deny_patterns and secret shapes run too, and name only the rule", %{tmp_dir: dir} do
      plan = page_plan(dir)
      config = %{@config | deny_patterns: ["Initech"]}

      assert {:ok, %{pairs: [pair]}} =
               run(dir, plan, %{dom_text: ["Initech Ltd"]}, config: config)

      assert %{rule: "deny-pattern:1"} = pair.after

      assert {:ok, %{pairs: [pair]}} =
               run(dir, plan, %{dom_text: ["-----BEGIN PRIVATE KEY-----"]})

      assert %{rule: "secret:private-key"} = pair.after
    end

    test "a clean page keeps its image", %{tmp_dir: dir} do
      assert {:ok, %{pairs: [pair]}} = run(dir, page_plan(dir), %{dom_text: ["pat@example.com"]})
      assert %{status: :ok} = pair.after
    end

    test "a shooter that reports no text is not trusted: the shot is withheld", %{tmp_dir: dir} do
      assert {:ok, %{pairs: [pair]}} = run(dir, page_plan(dir), %{dom_text: :none})
      assert %{status: :withheld, rule: "scan-unavailable"} = pair.after
      refute File.exists?(pair.after |> Map.get(:file, "") |> to_string())
    end

    test "the reviewer brief never lists a withheld image as a file", %{tmp_dir: dir} do
      assert {:ok, result} = run(dir, page_plan(dir), %{dom_text: ["x@acme-corp.io"]})
      assert {:proceed, brief} = ScreenshotGate.route({:ok, result})
      refute brief =~ ".png"
    end
  end

  describe "data safety: the fixture marker probe (bd-995svb)" do
    alias Wardmast.Test.CaptureMarkerPlug

    setup do
      bandit = start_supervised!({Bandit, plug: CaptureMarkerPlug, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, base_url: "http://127.0.0.1:#{port}"}
    end

    defp marker_config(contains),
      do: %{
        @config
        | fixture_check: %{"marker" => %{"path" => "/health", "contains" => contains}}
      }

    test "a matching marker lets the boot proceed", %{tmp_dir: dir, base_url: base_url} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:ok, _} =
               run(dir, plan, %{base_url: base_url}, config: marker_config("data: fixture"))

      assert_received {:shoot, "before", _, _, _}
    end

    test "a mismatch aborts the boot and fails the capture with a clear reason", %{
      tmp_dir: dir,
      base_url: base_url
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, failure} =
               run(dir, plan, %{base_url: base_url}, config: marker_config("data: production"))

      assert failure.code == :fixture_marker_mismatch
      assert failure.role == "before"
      assert failure.message =~ "fixture_check"
      assert failure.message =~ "/health"
      refute failure.message =~ "SECRET-BODY"
      # nothing was shot, and the app that failed the probe was still stopped
      refute_received {:shoot, _, _, _, _}
      assert_received {:stop, "before", _}

      recorded = recorded(dir)
      assert recorded["state"] == "failed"
      assert recorded["failure"]["code"] == "fixture_marker_mismatch"
      refute File.read!(Path.join([dir, "out", "capture.json"])) =~ "SECRET-BODY"
    end

    @login %{
      "kind" => "form",
      "path" => "/login",
      "username_selector" => "#u",
      "password_selector" => "#p",
      "submit_selector" => "#go",
      "default_persona" => "a",
      "personas" => %{"a" => %{"username" => "a", "password" => "b"}}
    }

    # /patients-style marker: gated behind the login, so an anonymous GET can never pass it.
    defp gated_config(extra \\ %{}),
      do: %{
        @config
        | login: @login,
          fixture_check: %{
            "marker" => Map.merge(%{"path" => "/patients", "contains" => "Jordan Ellis"}, extra)
          }
      }

    test "with a login the anonymous probe does not run: the shooter's session checks it", %{
      tmp_dir: dir,
      base_url: base_url
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      # The marker plug answers 404 to /patients: were the anonymous probe made, it would fail.
      assert {:ok, _} = run(dir, plan, %{base_url: base_url}, config: gated_config())
      assert_received {:shoot, "before", _, _, _}
    end

    test "a login config with marker.auth false still probes anonymously", %{
      tmp_dir: dir,
      base_url: base_url
    } do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, failure} =
               run(dir, plan, %{base_url: base_url}, config: gated_config(%{"auth" => false}))

      assert failure.code == :fixture_marker_mismatch
      refute_received {:shoot, _, _, _, _}
    end

    test "a marker the logged-in shooter rejects blocks every shot, without page content", %{
      tmp_dir: dir,
      base_url: base_url
    } do
      plan =
        write_plan!(dir, [%{"id" => "home", "path" => "/"}, %{"id" => "other", "path" => "/"}])

      reason = "fixture_check: GET /patients after login answered 302, not 200 with the marker"

      assert {:error, failure} =
               run(dir, plan, %{base_url: base_url, shoot_error: {:fixture_marker, reason}},
                 config: gated_config()
               )

      assert failure.code == :fixture_marker_mismatch
      assert failure.role == "before"
      assert failure.message =~ "nothing was shot"
      assert failure.message =~ "/patients"
      refute failure.message =~ "SECRET-BODY"
      # the first shot's refusal stops the run: the second is never taken, and the app is stopped
      assert_received {:shoot, "before", _, _, _}
      refute_received {:shoot, _, _, _, _}
      assert_received {:stop, "before", _}

      recorded = recorded(dir)
      assert recorded["state"] == "failed"
      assert recorded["failure"]["code"] == "fixture_marker_mismatch"
    end

    test "no fixture_check means no probe", %{tmp_dir: dir} do
      plan = write_plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:ok, _} = run(dir, plan)
    end
  end

  defp poster_row(%{label: label, before: b, after: a}),
    do: %{label: label, before: poster_cell(b), after: poster_cell(a)}

  defp poster_cell({:text, _} = text), do: text
  defp poster_cell(%{name: name}), do: {:image, "https://example.test/#{name}"}

  defp recorded(dir),
    do: Path.join([dir, "out", "capture.json"]) |> File.read!() |> Jason.decode!()
end
