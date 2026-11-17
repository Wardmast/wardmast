defmodule Wardmast.Test.OrphanedAgent do
  @moduledoc """
  A real stand-in for an agent a server crash left running (bd-568ib9), for the
  boot sweep's tests.

  It is launched through `Wardmast.Worker.ProcessGroup`'s warden launcher by a
  shell that exits at once. So, like an agent whose BEAM (and with it its
  `erl_child_setup`) died, it is reparented to init or a subreaper; as that
  shell's background job it does not lead a group, so the launcher's setsid()
  gives it its own session and group, with the warden in it. It leaves a child
  in its group (reparented to init too) and runs until killed.

  Everything it starts is killed again when the calling test exits. Call from
  the test process.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Wardmast.Worker.ProcessGroup

  @doc "Start one; returns `{leader_pid, child_pid}`."
  @spec spawn!() :: {pos_integer(), pos_integer()}
  def spawn! do
    script = "echo $$; (sleep 60 >/dev/null 2>&1 & echo $!); exec sleep 60"

    %{argv: argv} =
      ProcessGroup.wrap(
        %{exec: "/bin/sh", argv: ["/bin/sh", "-c", script], cd: "/"},
        enabled: true
      )

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args: ["-c", "\"$@\" &", "sh" | argv]
      ])

    {:os_pid, launching_shell} = Port.info(port, :os_pid)
    leader = read_pid!(port)
    child = read_pid!(port)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", "-#{leader}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{child}"], stderr_to_stdout: true)
    end)

    await_reparented(leader, launching_shell, 250)
    {leader, child}
  end

  @doc "Whether `pid` is a live process (`kill -0`)."
  @spec alive?(integer()) :: boolean()
  def alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  @doc "Wait (bounded) for `pid` to be gone; SIGKILLed processes linger until reaped."
  @spec gone?(integer(), non_neg_integer()) :: boolean()
  def gone?(pid, attempts \\ 150)
  def gone?(pid, 0), do: not alive?(pid)

  def gone?(pid, attempts) do
    if alive?(pid) do
      Process.sleep(20)
      gone?(pid, attempts - 1)
    else
      true
    end
  end

  defp read_pid!(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> line |> String.trim() |> String.to_integer()
    after
      5_000 -> flunk("the orphaned agent stand-in printed nothing")
    end
  end

  defp await_reparented(_leader, _shell, 0), do: flunk("the stand-in was never reparented")

  defp await_reparented(leader, shell, attempts) do
    case System.cmd("ps", ["-o", "ppid=", "-p", "#{leader}"]) do
      {out, 0} ->
        if String.trim(out) == "#{shell}" do
          Process.sleep(20)
          await_reparented(leader, shell, attempts - 1)
        else
          :ok
        end

      _ ->
        flunk("the stand-in exited")
    end
  end
end
