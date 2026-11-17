defmodule Arbiter.Repo.Migrations.AddProcessGroupToWorkerRuns do
  @moduledoc """
  Adds `worker_runs.os_pid`, `os_pgid` and `os_started_at` (bd-568ib9, MAC P2-1).

  A run's agent leads its own OS process group (`Wardmast.Worker.ProcessGroup`).
  Recording the agent's pid, that group and the process's start time on the run
  is what lets the next boot kill the group a crash left running, and only that
  group: the sweep acts only while the process at `os_pid` still started at
  `os_started_at`, so a pid the OS has since handed to something else is left
  alone. Only a run's latest local spawn is recorded.

  Nullable and never backfilled: NULL means a run on a node, a run whose start
  time could not be read, or one that predates the columns. Additive and safe
  to hot-run; rollback drops the columns.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :os_pid, :bigint
      add :os_pgid, :bigint
      add :os_started_at, :utc_datetime
    end
  end

  def down do
    alter table(:worker_runs) do
      remove :os_started_at
      remove :os_pgid
      remove :os_pid
    end
  end
end
