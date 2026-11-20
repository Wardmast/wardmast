defmodule Arbiter.Repo.Migrations.CreateScreenshotCaptures do
  @moduledoc """
  The durable record of the screenshot capture lifecycle (bd-8qj1sa): one row per
  capture *attempt* for a ticket, keyed by the head and merge-base it was taken at
  plus a hash of the plan and of the resolved `screenshots` config it ran with.

  Before this table the only state was `capture.json` on disk and the ReviewGate's
  in-memory `screenshot_checked`, so a restart forgot which head had been captured,
  nothing could say a capture had been superseded, and `max_captures_per_ticket`
  had nothing to count.

  `task_id` has no foreign key, like `ticket_attachments`: the row is history and
  outlives nothing that needs it to.
  """

  use Ecto.Migration

  def change do
    create table(:screenshot_captures, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, :text, null: false
      add :workspace_id, :text
      add :head_sha, :text, null: false
      add :base_sha, :text, null: false
      # sha256 of the plan the capture shot (NULL: no plan file, `default_routes` applied).
      add :plan_hash, :text
      # sha256 of the resolved `screenshots` config the capture ran with.
      add :config_hash, :text, null: false
      # running | captured | skipped | failed | superseded (`Wardmast.Screenshots.CaptureRecord`).
      add :state, :text, null: false
      # Why a `skipped` / `failed` / `superseded` attempt ended as it did.
      add :reason, :text
      add :failure_code, :text
      add :pair_count, :integer
      add :out_dir, :text
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:screenshot_captures, [:task_id, :inserted_at])
    create index(:screenshot_captures, [:task_id, :state])
  end
end
