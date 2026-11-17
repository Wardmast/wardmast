defmodule Arbiter.Repo.Migrations.CreatePreviewLeases do
  @moduledoc """
  App previews (`Wardmast.Preview`): one row per (repo, task_id) preview, and the
  port lease. `port` is unique, so two previews can never hold one — the
  guarantee is the index, not the allocator's care. A stopped or failed preview
  releases its port (`port` -> NULL; SQLite treats NULLs as distinct).
  """

  use Ecto.Migration

  def change do
    create table(:preview_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo, :text, null: false
      add :task_id, :text, null: false
      add :workspace_id, :text
      add :port, :integer
      add :status, :text, null: false
      add :os_pid, :integer
      add :url, :text
      add :log_path, :text
      add :checkout_path, :text
      add :checkout_kind, :text
      add :checkout_note, :text
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :touched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:preview_leases, [:repo, :task_id])
    create unique_index(:preview_leases, [:port])
  end
end
