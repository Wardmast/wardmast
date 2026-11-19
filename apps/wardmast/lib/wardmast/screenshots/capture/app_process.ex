defmodule Wardmast.Screenshots.Capture.AppProcess do
  @moduledoc """
  Owns one OS process of a capture boot (a setup script, a seed command or the app itself): runs
  `sh -c <command>` in its own process group with an **empty** environment plus the given pairs,
  keeps the last #{4096} bytes of its output, and kills the whole group on `stop/1` or when its
  owner dies (it is linked to the process that started it).

  The group is what makes `stop/1` reliable: `mix phx.server`'s BEAM and any watcher it spawned
  share the shell's group, so one signal reaches them all. The shell is made a group leader by a
  tiny perl `setpgrp` shim when it does not already lead one (the `Wardmast.Preview.Runner`
  technique); without perl the descendant walk (`Wardmast.Worker.OsProcess`) is the fallback.
  """

  use GenServer, restart: :temporary

  alias Wardmast.Worker.OsProcess
  alias Wardmast.Worker.ProcessGroup
  alias Wardmast.Worker.ReleaseEnv

  @tail_bytes 4096
  @term_grace_polls 150

  @type status :: :running | {:exited, integer()}

  @doc "Start `command` (`sh -c`) in `cd` with exactly `env` (`[{name, value}]`) as its environment."
  @spec start_link(%{command: String.t(), cd: String.t(), env: [{String.t(), String.t()}]}) ::
          GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Whether the process is still running, and the tail of its output."
  @spec status(pid()) :: {status(), String.t()}
  def status(pid), do: GenServer.call(pid, :status)

  @doc """
  Wait for the process to exit, up to `timeout_ms`. `{:exited, code, tail}` or `{:timeout, tail}`
  (the process is left running; the caller stops it).
  """
  @spec await_exit(pid(), non_neg_integer()) ::
          {:exited, integer(), String.t()} | {:timeout, String.t()}
  def await_exit(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(pid, deadline)
  end

  defp do_await(pid, deadline) do
    case status(pid) do
      {{:exited, code}, tail} ->
        {:exited, code, tail}

      {:running, tail} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, tail}
        else
          Process.sleep(50)
          do_await(pid, deadline)
        end
    end
  end

  @doc "Kill the process group and stop the server. Returns `:ok` also when already stopped."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop, 30_000)
  catch
    :exit, _ -> :ok
  end

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(%{command: command, cd: cd, env: env}) do
    Process.flag(:trap_exit, true)
    sh = System.find_executable("sh") || "/bin/sh"
    envbin = System.find_executable("env") || "/usr/bin/env"
    inner = ["-i"] ++ Enum.map(env, fn {k, v} -> "#{k}=#{v}" end) ++ [sh, "-c", command]
    {exec, args} = launcher(envbin, inner)

    port =
      Port.open({:spawn_executable, exec}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: cd,
        env: port_env()
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:ok, %{port: port, os_pid: os_pid, group?: group_leader?(os_pid), tail: "", exit: nil}}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, {if(state.exit, do: {:exited, state.exit}, else: :running), state.tail}, state}

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, kill(state)}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, %{state | tail: keep_tail(state.tail <> data)}}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state),
    do: {:noreply, %{state | exit: code}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill(state)
    :ok
  end

  defp keep_tail(bin) when byte_size(bin) <= @tail_bytes, do: bin
  defp keep_tail(bin), do: binary_part(bin, byte_size(bin) - @tail_bytes, @tail_bytes)

  # ── process control ─────────────────────────────────────────────────────

  # `Port.open/2` wants charlist pairs, with `false` meaning "unset".
  defp port_env do
    Enum.map(ReleaseEnv.port_env([]), fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp launcher(envbin, inner) do
    case System.find_executable("perl") do
      nil -> {envbin, inner}
      perl -> {perl, ["-e", "setpgrp(0,0) if getpgrp(0) != $$; exec @ARGV", envbin | inner]}
    end
  end

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

  defp kill(%{os_pid: nil} = state), do: close(state)

  defp kill(%{os_pid: os_pid} = state) do
    # The perl shim may not have called `setpgrp` yet when `init/1` first looked, so ask again
    # now that the process has had time to run.
    group? = state.group? or group_leader?(os_pid)
    descendants = OsProcess.descendants(os_pid)

    if group? do
      System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
    else
      Enum.each(
        [os_pid | descendants],
        &System.cmd("kill", ["-TERM", "#{&1}"], stderr_to_stdout: true)
      )
    end

    unless OsProcess.gone?(os_pid, @term_grace_polls) do
      if group?, do: ProcessGroup.kill(os_pid)
      OsProcess.kill_tree(os_pid)
    end

    # A detached child can outlive the leader.
    if group?, do: ProcessGroup.kill(os_pid)
    Enum.each(descendants, &System.cmd("kill", ["-KILL", "#{&1}"], stderr_to_stdout: true))
    close(%{state | os_pid: nil})
  end

  defp close(%{port: port} = state) do
    Port.close(port)
    state
  rescue
    _ -> state
  catch
    _, _ -> state
  end
end
