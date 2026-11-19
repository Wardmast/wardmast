defmodule Arbiter.Repo.Migrations.CreateTicketAttachments do
  @moduledoc """
  Ticket attachments (`Wardmast.Attachments`, bd-5hlegn): one row per image on a
  ticket. The bytes live on disk, content-addressed (`<root>/<workspace>/<sha[0:2]>/<sha>.<ext>`);
  the row is metadata and provenance.

  `task_id` deliberately has no foreign key: a hard-deleted ticket's rows (and
  the blobs only they reference) are removed by `Wardmast.Attachments.purge_task/1`
  from the ticket's destroy action, and a row outlives its blob after the
  retention prune (`pruned_at` set, provenance and `sha256` kept).
  """

  use Ecto.Migration

  def change do
    create table(:ticket_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, :text, null: false
      add :workspace_id, :text, null: false
      add :filename, :text
      add :caption, :text
      add :content_type, :text, null: false
      add :byte_size, :integer, null: false
      add :width, :integer
      add :height, :integer
      add :sha256, :text, null: false
      # "worker" | "coordinator" | "operator" | "arbiter-capture" (only Arbiter writes the last).
      add :source, :text, null: false
      # "before" | "after" | NULL; with `shot_id`/`viewport`/`theme` it keys a before/after pair.
      add :role, :text
      add :shot_id, :text
      add :viewport, :text
      add :theme, :text
      # Capture provenance (design §3); NULL for hand-attached files.
      add :capture_id, :text
      add :head_sha, :text
      add :base_sha, :text
      # Set when the blob was deleted by retention; the row stays.
      add :pruned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ticket_attachments, [:task_id, :inserted_at])
    create index(:ticket_attachments, [:workspace_id, :sha256])
  end
end
