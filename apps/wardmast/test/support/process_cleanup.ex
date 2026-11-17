defmodule Wardmast.Test.ProcessCleanup do
  @moduledoc """
  Teardown helpers for processes that may stop themselves mid-test.

  A Watchdog (or similar) that has merged its PR terminates on its own. The
  usual `if Process.alive?(pid), do: GenServer.stop(pid)` cleanup is a
  check-then-act race against that: the pid can exit between the two calls and
  `GenServer.stop/2` then exits with `:noproc`, failing the test from its
  `on_exit` callback (the `watchdog_baseline_carry_test` flake).
  """

  @doc """
  Stop `pid` and wait until it is down. Returns `:ok` whether this call stopped
  it or it had already exited on its own — either way the postcondition
  ("the process is gone") holds, which is all a teardown needs.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    try do
      GenServer.stop(pid, :normal)
    catch
      # `:noproc` (already gone) or the process exiting while we stop it.
      :exit, _reason -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
