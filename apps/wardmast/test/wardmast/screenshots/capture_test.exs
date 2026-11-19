defmodule Wardmast.Screenshots.CaptureTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Config
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
        config: @config,
        plan_path: plan_path,
        out_dir: Path.join(dir, "out")
      },
      [booter: CaptureStubBooter, shooter: CaptureStubShooter, ctx: ctx] ++ opts
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
               shooter: CaptureStubShooter,
               ctx: ctx
             )
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

  defp recorded(dir),
    do: Path.join([dir, "out", "capture.json"]) |> File.read!() |> Jason.decode!()
end
