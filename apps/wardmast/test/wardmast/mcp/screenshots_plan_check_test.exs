defmodule Wardmast.MCP.ScreenshotsPlanCheckTest do
  @moduledoc """
  bd-adrym0: the worker-tier `screenshots_plan_check` tool (twin of `ward screenshots check`)
  answers what the `arb done` commit gate will answer for the plan.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.MCP.Catalog
  alias Wardmast.MCP.Scope
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker

  defp git(dir, args),
    do:
      {_, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
          cd: dir,
          stderr_to_stdout: true
        )

  setup do
    dir = Path.join(System.tmp_dir!(), "spc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    git(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "x")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "base"])
    git(dir, ["checkout", "-q", "-b", "feat"])
    File.mkdir_p!(Path.join(dir, "web"))
    File.write!(Path.join(dir, "web/a.ex"), "x")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "ui"])

    config = %{
      "worker" => %{"screenshots" => %{"ui_paths" => ["web/**"], "start_cmd" => "true"}}
    }

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "spc-#{System.unique_integer([:positive])}",
        prefix: "spc",
        config: config
      })

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :feature})
    task = put_state!(task, :active)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "spc/repo",
        workspace_id: ws.id,
        meta: %{worktree_path: dir, target_branch: "main", review_spawn: false}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    %{
      dir: dir,
      task: task,
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id},
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}
    }
  end

  defp check(scope, args \\ %{}), do: Catalog.call(scope, "screenshots_plan_check", args)

  test "is a worker-tier tool", ctx do
    assert {:ok, %{tiers: [:worker]}} = Catalog.fetch("screenshots_plan_check")
    assert {:rpc_error, _, _} = check(ctx.coordinator)
  end

  test "a missing plan on a UI diff is not ok", ctx do
    assert {:ok, %{ok: false, status: "invalid", messages: [msg | _]}} = check(ctx.worker)
    assert msg =~ "screenshots.json"
  end

  test "a valid plan and a valid skip are ok", ctx do
    File.mkdir_p!(Path.join(ctx.dir, ".arbiter"))
    path = Path.join(ctx.dir, ".arbiter/screenshots.json")

    File.write!(path, ~s({"version":1,"shots":[{"id":"home","path":"/"}]}))
    assert {:ok, %{ok: true, status: "ok", sha: sha}} = check(ctx.worker)
    assert is_binary(sha)

    File.write!(path, ~s({"version":1,"skip":"copy only"}))
    assert {:ok, %{ok: true, status: "skip"}} = check(ctx.worker)
  end
end
