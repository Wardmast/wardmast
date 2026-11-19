defmodule Wardmast.MCP.RunTestsTest do
  @moduledoc """
  bd-57nhsi: the worker-tier `run_tests` tool. A worker runs `mix test` through
  Wardmast, in its run's own environment, and gets counts plus each failure
  instead of the raw ExUnit output.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.MCP.Catalog
  alias Wardmast.MCP.Scope
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker

  @green "Compiling 40 files\nwarning: noisy\n.....\n5 tests, 0 failures\n"

  @red """
  Compiling 40 files

    1) test it works (Core.XTest)
       test/x_test.exs:4
       Assertion with == failed
       code:  assert 1 == 2
       left:  1
       right: 2
       stacktrace:
         test/x_test.exs:5: (test)

  1 test, 1 failure
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "run-tests-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "rt-#{System.unique_integer([:positive])}", prefix: "rt"})

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :feature})
    task = put_state!(task, :active)
    {:ok, other} = Ash.create(Issue, %{title: "other", workspace_id: ws.id})

    %{
      dir: dir,
      task: task,
      other: other,
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id},
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}
    }
  end

  # An exec that answers the path probe and replays `output` for the run itself.
  defp start_worker(ctx, output, status, env \\ {"", 0}) do
    test_pid = self()

    exec = fn command, seconds ->
      send(test_pid, {:exec, command, seconds})

      cond do
        command =~ "test-env.sh" -> env
        command =~ "ARB_TEST_LOG" -> {"ARB_TEST_LOG=/run/tmp/arb-test-1.log\n" <> output, status}
        true -> {"apps/core/test/x_test.exs\n", 0}
      end
    end

    {:ok, pid} =
      Worker.start(
        task_id: ctx.task.id,
        repo: "rt/repo",
        workspace_id: ctx.task.workspace_id,
        meta: %{
          worktree_path: ctx.dir,
          target_branch: "main",
          prepush_exec: exec,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp run_tests(scope, args), do: Catalog.call(scope, "run_tests", args)

  test "is a worker-tier tool" do
    assert {:ok, %{tiers: [:worker]}} = Catalog.fetch("run_tests")

    assert {:rpc_error, _, _} =
             run_tests(%Scope{tier: :coordinator, workspace_id: "w"}, %{"paths" => ["a"]})
  end

  test "a green run returns counts and the log path, without the output", ctx do
    start_worker(ctx, @green, 0)

    assert {:ok, result} = run_tests(ctx.worker, %{"paths" => ["apps/core/test/x_test.exs"]})

    assert result.status == "passed"
    assert result.summary =~ "5 tests, 0 failures"
    assert result.full_log == "/run/tmp/arb-test-1.log"
    refute inspect(result) =~ "noisy"
  end

  describe "tests not run (bd-7m35lc)" do
    test "a test env that cannot come up is a distinct error, not a bare DATABASE_URL failure",
         ctx do
      start_worker(ctx, @green, 0, {"cannot reach postgres", 3})

      assert {:tool_error, message, _} =
               run_tests(ctx.worker, %{"paths" => ["apps/core/test/x_test.exs"]})

      assert message =~ "test env unavailable"
      assert message =~ "cannot reach postgres"
      refute message =~ "DATABASE_URL"
    end

    test "only failed attempts flag the run; a real result clears it", ctx do
      pid = start_worker(ctx, @green, 0, {"boom", 1})
      refute Wardmast.Worker.TestSignal.not_run?(:sys.get_state(pid).meta)

      assert {:tool_error, _, _} =
               run_tests(ctx.worker, %{"paths" => ["apps/core/test/x_test.exs"]})

      assert Wardmast.Worker.TestSignal.not_run?(:sys.get_state(pid).meta)

      Wardmast.Worker.note_test_outcome(ctx.task.id, :ran)
      refute Wardmast.Worker.TestSignal.not_run?(:sys.get_state(pid).meta)
    end
  end

  test "a red run returns each failure and the log path", ctx do
    start_worker(ctx, @red, 2)

    assert {:ok, result} = run_tests(ctx.worker, %{"paths" => ["apps/core/test/x_test.exs"]})

    assert result.status == "failed"
    assert result.summary =~ "1) test it works (Core.XTest)"
    assert result.summary =~ "right: 2"
    refute result.summary =~ "Compiling"
    assert result.full_log == "/run/tmp/arb-test-1.log"
  end

  test "the timeout is passed to the run and capped", ctx do
    start_worker(ctx, @green, 0)

    assert {:ok, _} =
             run_tests(ctx.worker, %{"paths" => ["a_test.exs"], "timeout_seconds" => 99_999})

    assert_received {:exec, command, seconds} when seconds <= 60
    assert command =~ "a_test.exs"
    assert_received {:exec, _run, 1800}
  end

  test "a bad request is an invalid-params error, not a run", ctx do
    start_worker(ctx, @green, 0)

    assert {:tool_error, message, _type} = run_tests(ctx.worker, %{})
    assert message =~ "paths"
    refute_received {:exec, _, _}

    assert {:tool_error, _, _} = run_tests(ctx.worker, %{"paths" => ["--cover"]})
    assert {:tool_error, _, _} = run_tests(ctx.worker, %{"paths" => "not-a-list"})
  end

  test "a worker may only run its own task's tests", ctx do
    start_worker(ctx, @green, 0)

    assert {:rpc_error, _, _} =
             run_tests(ctx.worker, %{"id" => ctx.other.id, "paths" => ["a_test.exs"]})
  end

  test "no live worker for the task is a clear error", ctx do
    assert {:tool_error, message, _} = run_tests(ctx.worker, %{"paths" => ["a_test.exs"]})
    assert message =~ "no live worker"
  end
end
