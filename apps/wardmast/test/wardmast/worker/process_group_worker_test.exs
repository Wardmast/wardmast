defmodule Wardmast.Worker.ProcessGroupWorkerTest do
  # bd-568ib9 (MAC P2-1): the Worker records its agent's process group on the
  # run, and kills the group once the agent has exited, so nothing the agent
  # backgrounded outlives the run. Before this the post-exit reap was the
  # systemd scope's alone (bd-6zm33r): with no scope (macOS, a host without a
  # user manager, `WARDMAST_WORKER_MEMORY_MAX=off` as in this suite) a
  # backgrounded `mix test` or dev server ran on after the run ended.
  #
  # The group warden would kill the leftovers by itself
  # (`Wardmast.Worker.ProcessGroup`), so it is off where the test is about what
  # the Worker does.
  #
  # async: false: the Worker writes its run row from its own process (shared
  # sandbox), the global worker registry, app env, and real OS processes.
  use Wardmast.DataCase, async: false

  alias Wardmast.Worker
  alias Wardmast.Worker.ClaudeSession
  alias Wardmast.Worker.OsProcess
  alias Wardmast.Workers.Run
  require Ash.Query

  defp start_worker! do
    task_id = "bd-pgroup-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-pgroup")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :implement)
    {pid, task_id}
  end

  defp run_for(task_id) do
    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    run
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The pid a script left in `orphan.pid`; killed again on exit whatever happens.
  defp orphan_pid!(dir) do
    path = Path.join(dir, "orphan.pid")
    eventually(fn -> File.exists?(path) and File.read!(path) =~ ~r/\A\d+\n\z/ end)
    pid = path |> File.read!() |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true) end)
    pid
  end

  defp os_process_alive?(os_pid) do
    {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    code == 0
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end

      value ->
        value
    end
  end

  # Save-and-restore, never put+delete: deleting would also wipe a value
  # config/test.exs set.
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

  # Backgrounds a `sleep` from a subshell that exits at once: the `sleep` is
  # reparented to init, out of reach of the `pgrep -P` tree walk, but still in
  # the agent's process group.
  @leave_orphan "(sleep 60 >/dev/null 2>&1 & echo $! > orphan.pid)"

  test "records the agent's pid, process group and start time on its run" do
    {pid, task_id} = start_worker!()
    cwd = tmp_dir!("pgroup-record")

    {:ok, port} =
      ClaudeSession.start(owner: pid, worktree_path: cwd, command: ["sh", "-c", "sleep 60"])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    run = run_for(task_id)
    assert run.os_pid == os_pid
    assert run.os_pgid == os_pid
    assert %DateTime{} = run.os_started_at
    assert abs(DateTime.diff(run.os_started_at, DateTime.utc_now())) <= 5
  end

  test "once the agent exits, the worker kills what it left running in its group" do
    put_env!(:worker_group_warden, false)
    {pid, _task_id} = start_worker!()
    cwd = tmp_dir!("pgroup-reap")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", @leave_orphan <> "; exit 0"]
      )

    orphan = orphan_pid!(cwd)
    eventually(fn -> Worker.state(pid).meta[:exit_status] end)

    eventually(fn -> not os_process_alive?(orphan) end)
  end

  test "a fail teardown kills what the agent left running in its group" do
    put_env!(:worker_group_warden, false)
    {pid, _task_id} = start_worker!()
    cwd = tmp_dir!("pgroup-fail")

    {:ok, port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", @leave_orphan <> "; exec sleep 60"]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    orphan = orphan_pid!(cwd)
    eventually(fn -> orphan not in OsProcess.descendants(os_pid) end)

    :ok = Worker.fail(pid, :simulated_failure)
    _ = :sys.get_state(pid)

    refute os_process_alive?(os_pid)
    eventually(fn -> not os_process_alive?(orphan) end)
  end
end
