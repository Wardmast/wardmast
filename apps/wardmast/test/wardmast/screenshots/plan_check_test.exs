defmodule Wardmast.Screenshots.PlanCheckTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.PlanCheck

  @valid ~s({"version":1,"shots":[{"id":"home","path":"/"}]})
  @skip ~s({"version":1,"skip":"copy-only change"})

  setup do
    dir = Path.join(System.tmp_dir!(), "plan-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "x")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "base"])
    {:ok, dir: dir, config: config(%{})}
  end

  defp config(extra) do
    {:ok, c} =
      Config.resolve(
        %{
          config: %{
            "worker" => %{
              "screenshots" =>
                Map.merge(%{"ui_paths" => ["lib/web/**"], "start_cmd" => "mix phx.server"}, extra)
            }
          }
        },
        nil
      )

    c
  end

  defp git(dir, args),
    do:
      {_, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
          cd: dir,
          stderr_to_stdout: true
        )

  defp commit_ui(dir) do
    File.mkdir_p!(Path.join(dir, "lib/web"))
    File.write!(Path.join(dir, "lib/web/a.ex"), "x")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "ui"])
  end

  defp write_plan(dir, body) do
    File.mkdir_p!(Path.join(dir, ".arbiter"))
    File.write!(Path.join(dir, ".arbiter/screenshots.json"), body)
  end

  test "not applicable when the diff does not touch ui_paths", %{dir: dir, config: c} do
    assert :not_applicable = PlanCheck.check(c, dir, "main")
  end

  test "the base is origin/<target>, not a stale local branch", %{dir: dir, config: c} do
    remote = dir <> "-remote.git"
    on_exit(fn -> File.rm_rf!(remote) end)
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    git(dir, ["remote", "add", "origin", remote])
    commit_ui(dir)
    git(dir, ["push", "-q", "origin", "main"])
    git(dir, ["checkout", "-q", "-b", "feat"])
    # local main lags origin/main; the upstream-only commit touches ui_paths
    git(dir, ["branch", "-f", "main", "HEAD~1"])

    assert :not_applicable = PlanCheck.check(c, dir, "main")
  end

  test "an unresolvable base fails closed when plan_required", %{dir: dir, config: c} do
    assert {:error, [msg]} = PlanCheck.check(c, dir, "no-such-branch")
    assert msg =~ "merge base"

    assert :not_applicable =
             PlanCheck.check(config(%{"plan_required" => false}), dir, "no-such-branch")
  end

  test "missing plan on a UI diff is an error", %{dir: dir, config: c} do
    git(dir, ["checkout", "-q", "-b", "feat"])
    commit_ui(dir)
    assert {:error, [msg]} = PlanCheck.check(c, dir, "main")
    assert msg =~ "screenshots.json"
  end

  test "invalid plan lists the errors", %{dir: dir, config: c} do
    git(dir, ["checkout", "-q", "-b", "feat"])
    commit_ui(dir)
    write_plan(dir, ~s({"version":2}))
    assert {:error, [_ | _] = errors} = PlanCheck.check(c, dir, "main")
    assert Enum.any?(errors, &(&1 =~ "version"))
  end

  test "a valid plan and a valid skip pass, with the sha", %{dir: dir, config: c} do
    git(dir, ["checkout", "-q", "-b", "feat"])
    commit_ui(dir)
    write_plan(dir, @valid)
    assert {:ok, %{sha: sha, body: @valid}} = PlanCheck.check(c, dir, "main")
    assert sha == Base.encode16(:crypto.hash(:sha256, @valid), case: :lower)
    write_plan(dir, @skip)
    assert {:ok, %{skip: "copy-only change"}} = PlanCheck.check(c, dir, "main")
  end

  test "plan_required false lets a missing plan pass", %{dir: dir} do
    git(dir, ["checkout", "-q", "-b", "feat"])
    commit_ui(dir)
    assert {:ok, %{sha: nil}} = PlanCheck.check(config(%{"plan_required" => false}), dir, "main")
  end

  test "store/3 keeps the checked copy that read_stored/2 returns", %{dir: dir} do
    out = Path.join(dir, "store")
    :ok = PlanCheck.store(out, "t1", %{sha: PlanCheck.sha(@valid), body: @valid})
    assert PlanCheck.stored_path(out, "t1") |> File.read!() == @valid
    assert {:ok, sha} = PlanCheck.stored_sha(out, "t1")
    assert sha == PlanCheck.sha(@valid)
    File.write!(PlanCheck.stored_path(out, "t1"), "tampered")
    assert :error = PlanCheck.stored_sha(out, "t1")
  end

  test "excludes the plan from git", %{dir: dir} do
    :ok = PlanCheck.exclude_plan(dir)
    :ok = PlanCheck.exclude_plan(dir)
    {out, 0} = System.cmd("git", ["check-ignore", ".arbiter/screenshots.json"], cd: dir)
    assert out =~ "screenshots.json"
    exclude = File.read!(Path.join(dir, ".git/info/exclude"))
    assert length(String.split(exclude, ".arbiter/screenshots.json")) == 2
  end

  describe "gate/4 and merge_gate/2" do
    test "a UI diff with no plan is a red step that fails the run", %{dir: dir, config: c} do
      git(dir, ["checkout", "-q", "-b", "feat"])
      commit_ui(dir)
      gate = PlanCheck.gate(c, dir, "main", "t-gate-red")
      assert gate.step.status == :failed
      assert gate.step.name == "screenshots plan"

      merged = PlanCheck.merge_gate(%{result: :ok, steps: []}, gate)
      assert {:failed, 1, output} = merged.result
      assert output =~ "screenshots.json"
      assert [%{status: :failed}] = merged.steps
    end

    test "a valid skip passes, records the sha and excludes the plan", %{dir: dir, config: c} do
      git(dir, ["checkout", "-q", "-b", "feat"])
      commit_ui(dir)
      write_plan(dir, @skip)
      gate = PlanCheck.gate(c, dir, "main", "t-gate-ok")
      assert gate.step.status == :passed
      merged = PlanCheck.merge_gate(%{result: :ok, steps: []}, gate)
      assert merged.result == :ok
      assert merged.screenshots_plan.sha == PlanCheck.sha(@skip)
      assert {:ok, _} = PlanCheck.stored_sha(PlanCheck.store_root(), "t-gate-ok")
      File.rm_rf!(Path.join(PlanCheck.store_root(), "t-gate-ok"))
    end

    test "no UI change adds nothing", %{dir: dir, config: c} do
      assert PlanCheck.gate(c, dir, "main", "t-gate-none") == nil
      run = %{result: :ok, steps: []}
      assert PlanCheck.merge_gate(run, nil) == run
    end
  end

  describe "strip_committed/2" do
    defp commit_manifest(dir, body) do
      write_plan(dir, body)
      git(dir, ["add", "-f", ".arbiter/screenshots.json"])
      git(dir, ["commit", "-q", "-m", "manifest"])
    end

    test "removes a committed manifest from the branch but keeps the file", %{dir: dir} do
      git(dir, ["checkout", "-q", "-b", "feat"])
      commit_manifest(dir, @valid)

      assert :stripped = PlanCheck.strip_committed(dir, "main")
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "HEAD"], cd: dir)
      refute tree =~ "screenshots.json"
      assert File.read!(Path.join(dir, ".arbiter/screenshots.json")) == @valid
      assert :clean = PlanCheck.strip_committed(dir, "main")
    end

    test "leaves a manifest the target already carries", %{dir: dir} do
      commit_manifest(dir, @skip)
      git(dir, ["checkout", "-q", "-b", "feat"])
      assert :clean = PlanCheck.strip_committed(dir, "main")
    end

    test "two branches with their own manifest merge without a conflict", %{dir: dir} do
      for {b, body} <- [{"a", @valid}, {"b", @skip}] do
        git(dir, ["checkout", "-q", "-b", b, "main"])
        commit_manifest(dir, body)
        assert :stripped = PlanCheck.strip_committed(dir, "main")
      end

      git(dir, ["checkout", "-q", "main"])
      git(dir, ["merge", "-q", "--no-edit", "a"])
      git(dir, ["merge", "-q", "--no-edit", "b"])
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "HEAD"], cd: dir)
      refute tree =~ "screenshots.json"
    end
  end
end
