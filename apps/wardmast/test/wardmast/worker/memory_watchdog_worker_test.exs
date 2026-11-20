defmodule Wardmast.Worker.MemoryWatchdogWorkerTest do
  # bd-d627b8 (MAC P3-3): the Worker half of the macOS memory watchdog. A fake
  # sampler reports the agent's process group as over the cap; the real agent (a
  # `sleep`) must then be killed and the run recorded as `:memory_cap_exceeded`.
  # Runs on any Unix: the watchdog's `:memory_watchdog` app env stands in for the
  # darwin-only, env-configured cap.
  #
  # async: false: shared run-row sandbox, global worker registry, app env.
  use Wardmast.DataCase, async: false

  alias Wardmast.Worker
  alias Wardmast.Worker.ClaudeSession
  alias Wardmast.Workers.Run
  require Ash.Query

  @gib 1_073_741_824

  defp put_env!(key, value) do
    previous = Application.fetch_env(:wardmast, key)
    Application.put_env(:wardmast, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:wardmast, key, v)
        :error -> Application.delete_env(:wardmast, key)
      end
    end)
  end

  defp run_agent(command) do
    task_id = "bd-memwd-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-memwd")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    {:ok, port} =
      ClaudeSession.start(owner: pid, worktree_path: System.tmp_dir!(), command: command)

    {pid, port, task_id}
  end

  defp wait_finished(pid) do
    deadline = System.monotonic_time(:millisecond) + 8_000
    do_wait(pid, deadline)
  end

  defp do_wait(pid, deadline) do
    case Worker.state(pid) do
      %{state: :finished} = s ->
        s

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("worker never finished")
        Process.sleep(20)
        do_wait(pid, deadline)
    end
  end

  defp run_for(task_id) do
    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    run
  end

  test "a group over the cap is killed and the run fails as memory_cap_exceeded" do
    put_env!(:worker_group_warden, false)

    put_env!(:memory_watchdog,
      cap: {:ok, %{bytes: 1 * @gib, label: "1G"}},
      sampler: fn _pgid -> {:ok, 3 * @gib} end,
      interval_ms: 20
    )

    {pid, _port, task_id} = run_agent(["sh", "-c", "sleep 60"])
    state = wait_finished(pid)

    assert state.outcome == :failed
    assert state.meta.stop_reason.category == :memory_cap_exceeded

    run = run_for(task_id)
    assert run.stop_category == "memory_cap_exceeded"
    assert run.failure_reason =~ "memory cap exceeded"
    assert run.failure_reason =~ "1G"
    assert run.failure_reason =~ "3.0 GiB"
    assert run.failure_reason =~ "watchdog"
  end

  test "a group under the cap is left alone and the watchdog stops with the agent" do
    put_env!(:worker_group_warden, false)

    put_env!(:memory_watchdog,
      cap: {:ok, %{bytes: 1 * @gib, label: "1G"}},
      sampler: fn _pgid -> {:ok, 1024} end,
      interval_ms: 20
    )

    {pid, _port, task_id} = run_agent(["sh", "-c", "sleep 0.3; exit 0"])
    _ = wait_for_exit(pid)

    refute run_for(task_id).stop_category == "memory_cap_exceeded"
  end

  defp wait_for_exit(pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_wait_exit(pid, deadline)
  end

  defp do_wait_exit(pid, deadline) do
    case Worker.state(pid).meta[:exit_status] do
      nil ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("agent never exited")
        Process.sleep(20)
        do_wait_exit(pid, deadline)

      status ->
        status
    end
  end
end
