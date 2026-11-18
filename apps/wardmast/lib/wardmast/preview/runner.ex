defmodule Wardmast.Preview.Runner do
  @moduledoc """
  Owns one running app preview: the setup script, the startup command, its log
  and its readiness probe, as a supervised process.

  Started under `Wardmast.Preview.Supervisor`, registered in
  `Wardmast.Preview.Registry` by `{repo, task_id}`. It is the Port owner, so a
  Wardmast shutdown reaches `terminate/2`, which kills the preview's whole
  process group.

  ## Process group

  The command runs as `sh -c <command>` led by its own process group (a small
  perl `setpgrp` shim makes it so when the Port child does not already lead
  one); its children — `mix phx.server`'s BEAM, a `npm run dev` watcher tree —
  inherit the group. `stop/3` signals the group (`kill -- -PGID`): TERM first,
  KILL after a grace period, then any descendant the walk found beforehand.
  Where the shell cannot be made a group leader it degrades to the descendant
  walk alone (`Wardmast.Worker.OsProcess`).

  ## Phases


  `:setup` (only the first time for a preview directory, marked by
  `setup.done`) → `:starting` (command running, probing `ready_path`) →
  `:running`. Every transition is persisted on the lease row and broadcast on
  `Wardmast.Preview.topic/0`. A failure in any phase releases the port, keeps the
  row as `failed` with the reason and leaves the log for inspection.
  """

  use GenServer, restart: :temporary, shutdown: 20_000

  alias Wardmast.Preview
  alias Wardmast.Preview.Config
  alias Wardmast.Preview.Leases
  alias Wardmast.Worker.OsProcess
  alias Wardmast.Worker.SpawnEnv

  @probe_interval_ms 500
  @term_grace_polls 150

  # ---- API -----------------------------------------------------------------

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via(args.repo, args.task_id))
  end

  @doc "Registry name for a preview."
  def via(repo, task_id), do: {:via, Registry, {Wardmast.Preview.Registry, {repo, task_id}}}

  @doc "The runner pid for a preview, or nil."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(repo, task_id) do
    case Registry.lookup(Wardmast.Preview.Registry, {repo, task_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Stop the preview: kill its process group, release the port, delete the row.
  Returns `:ok`, also when nothing is running.
  """
  @spec stop(String.t(), String.t(), String.t()) :: :ok
  def stop(repo, task_id, reason \\ "stopped") do
    case whereis(repo, task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.call(pid, {:stop, reason}, 25_000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  # ---- GenServer -----------------------------------------------------------

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Path.dirname(args.log_path))
    {:ok, log} = File.open(args.log_path, [:append, :binary, :raw])

    state = %{
      repo: args.repo,
      task_id: args.task_id,
      lease_id: args.lease_id,
      cfg: args.config,
      checkout: args.checkout,
      port: args.port,
      state_dir: args.state_dir,
      log: log,
      log_path: args.log_path,
      extra_env: Map.get(args, :extra_env, []),
      phase: :init,
      os_port: nil,
      os_pid: nil,
      group?: false,
      deadline: nil,
      last_probe: nil
    }

    {:ok, state, {:continue, :begin}}
  end

  @impl true
  def handle_continue(:begin, state) do
    marker = Path.join(state.state_dir, "setup.done")

    if state.cfg.setup && not File.exists?(marker) do
      log(state, "==> setup: #{vars(state) |> render(state.cfg.setup)}\n")
      {:noreply, spawn_phase(state, :setup, render(vars(state), state.cfg.setup))}
    else
      {:noreply, start_command(state)}
    end
  end

  @impl true
  def handle_call({:stop, reason}, _from, state) do
    state = shutdown_process(state)
    log(state, "==> #{reason}\n")
    delete_row(state)
    {:stop, :normal, :ok, close_log(state)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{os_port: port} = state) do
    :file.write(state.log, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{os_port: port, phase: :setup} = state) do
    if code == 0 do
      File.write!(Path.join(state.state_dir, "setup.done"), "")
      {:noreply, start_command(%{state | os_port: nil, os_pid: nil})}
    else
      fail(%{state | os_port: nil}, "setup exited with status #{code}")
    end
  end

  def handle_info({port, {:exit_status, code}}, %{os_port: port} = state) do
    what = if state.phase == :running, do: "exited", else: "exited before it was ready"
    fail(%{state | os_port: nil}, "#{what} with status #{code}")
  end

  def handle_info(:probe, %{phase: :starting} = state) do
    case probe(state) do
      :ready ->
        log(state, "==> ready on port #{state.port}\n")
        update_row(state, status: "running", url: Preview.url(state.port), error: nil)
        {:noreply, %{state | phase: :running}}

      {:not_ready, detail} ->
        state = %{state | last_probe: detail}

        if System.monotonic_time(:millisecond) >= state.deadline do
          fail(
            state,
            "not ready after #{state.cfg.ready_timeout}s (GET #{state.cfg.ready_path}: #{detail})"
          )
        else
          Process.send_after(self(), :probe, @probe_interval_ms)
          {:noreply, state}
        end
    end
  end

  def handle_info(:probe, state), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, %{os_port: port} = state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = shutdown_process(state)
    if state.log, do: close_log(state)
    :ok
  end

  # ---- phases --------------------------------------------------------------

  defp start_command(state) do
    cmd = render(vars(state), state.cfg.command)
    log(state, "==> start: #{cmd}\n")
    state = spawn_phase(state, :starting, cmd)

    update_row(state,
      status: "starting",
      os_pid: state.os_pid
    )

    deadline = System.monotonic_time(:millisecond) + state.cfg.ready_timeout * 1000
    Process.send_after(self(), :probe, @probe_interval_ms)
    %{state | deadline: deadline}
  end

  defp spawn_phase(state, phase, command) do
    {exec, args} = launcher(command)

    port =
      Port.open({:spawn_executable, exec}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: state.checkout,
        env: env(state)
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    %{state | phase: phase, os_port: port, os_pid: os_pid, group?: group_leader?(os_pid)}
  end

  defp fail(state, reason) do
    log(state, "==> failed: #{reason}\n")
    state = shutdown_process(state)
    fail_row(state, reason)
    {:stop, :normal, close_log(state)}
  end

  # ---- process control -----------------------------------------------------

  # The shell must lead its own process group so `kill -- -PGID` reaches the
  # whole tree. A Port child may or may not already lead one, so a tiny perl
  # shim makes it so only when it does not (`setpgrp`, no fork: the pid we hold
  # stays the pid of the shell). Without perl the shell runs directly and
  # `group_leader?/1` decides whether a group kill is safe at all.
  defp launcher(command) do
    case System.find_executable("perl") do
      nil ->
        {System.find_executable("sh") || "/bin/sh", ["-c", command]}

      perl ->
        {perl, ["-e", "setpgrp(0,0) if getpgrp(0) != $$; exec @ARGV", "sh", "-c", command]}
    end
  end

  # Group kill is only safe when the pid we hold leads its own group.
  defp group_leader?(nil), do: false

  defp group_leader?(os_pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out) == Integer.to_string(os_pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp shutdown_process(%{os_pid: nil} = state), do: close_port(state)

  defp shutdown_process(%{os_pid: os_pid, group?: group?} = state) do
    descendants = OsProcess.descendants(os_pid)

    if group? do
      signal_group("-TERM", os_pid)
    else
      Enum.each([os_pid | descendants], &signal_pid("-TERM", &1))
    end

    unless OsProcess.gone?(os_pid, @term_grace_polls) and group_gone?(group?, os_pid) do
      if group?, do: signal_group("-KILL", os_pid)
      OsProcess.kill_tree(os_pid)
    end

    Enum.each(descendants, &signal_pid("-KILL", &1))
    close_port(%{state | os_pid: nil})
  end

  # The leader exiting does not mean the group is empty (a detached child).
  defp group_gone?(false, _os_pid), do: true

  defp group_gone?(true, os_pid) do
    match?(
      {_, n} when n != 0,
      System.cmd("kill", ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true)
    )
  end

  defp signal_group(sig, pgid),
    do: System.cmd("kill", [sig, "--", "-#{pgid}"], stderr_to_stdout: true)

  defp signal_pid(sig, pid),
    do: System.cmd("kill", [sig, Integer.to_string(pid)], stderr_to_stdout: true)

  defp close_port(%{os_port: nil} = state), do: state

  defp close_port(%{os_port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    %{state | os_port: nil}
  end

  # ---- helpers -------------------------------------------------------------

  defp vars(state),
    do: %{
      port: state.port,
      task_id: state.task_id,
      checkout: state.checkout,
      host: Preview.host()
    }

  defp render(vars, template), do: Config.render(template, vars)

  defp env(state) do
    vars = vars(state)
    user = Enum.map(state.cfg.env, fn {k, v} -> {k, render(vars, v)} end)

    pairs =
      [{state.cfg.port_env, Integer.to_string(state.port)}] ++
        user ++ state.extra_env ++ [{"WARDMAST_PREVIEW", "1"}]

    pairs
    |> SpawnEnv.port_env(nil)
    |> Enum.map(fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp probe(state) do
    url = "http://#{Preview.host()}:#{state.port}#{state.cfg.ready_path}"

    result =
      try do
        Req.get(url,
          retry: false,
          receive_timeout: 1_500,
          connect_options: [timeout: 1_000],
          redirect: false
        )
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, %{status: status}} when status < 500 -> :ready
      {:ok, %{status: status}} -> {:not_ready, "HTTP #{status}"}
      {:error, _} -> {:not_ready, "no answer"}
    end
  end

  defp delete_row(state) do
    case Wardmast.Repo.get(Wardmast.Preview.Lease, state.lease_id) do
      nil -> :ok
      row -> Leases.delete(row)
    end

    Preview.broadcast()
  end

  defp fail_row(state, reason) do
    case Wardmast.Repo.get(Wardmast.Preview.Lease, state.lease_id) do
      nil ->
        :ok

      row ->
        {:ok, row} = Leases.update(row, %{status: "failed", error: reason})
        {:ok, _} = Leases.release(row)
    end

    Preview.broadcast()
  end

  defp update_row(state, attrs) do
    case Wardmast.Repo.get(Wardmast.Preview.Lease, state.lease_id) do
      nil -> :ok
      row -> Leases.update(row, Map.new(attrs))
    end

    Preview.broadcast()
  end

  defp log(%{log: log}, line) when not is_nil(log), do: :file.write(log, line)
  defp log(_state, _line), do: :ok

  defp close_log(%{log: nil} = state), do: state

  defp close_log(%{log: log} = state) do
    File.close(log)
    %{state | log: nil}
  end
end
