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
end
