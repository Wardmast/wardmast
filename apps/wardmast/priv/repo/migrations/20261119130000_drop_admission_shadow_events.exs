defmodule Arbiter.Repo.Migrations.DropAdmissionShadowEvents do
  @moduledoc """
  DC12 (bd-b3u00u): the reverse shadow compared the walk with today's plan, and
  today's plan is gone, so nothing writes `admission_shadow_events` any more.
  Rollback re-creates the empty table (the rows are not restored).
  """

  use Ecto.Migration

  def up do
    drop table(:admission_shadow_events)
  end

  def down do
    create table(:admission_shadow_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :at, :utc_datetime_usec, null: false
      add :policy, :text, null: false
      add :legacy_pick, :text
      add :walk_pick, :text
      add :agrees, :boolean, null: false
      add :comparable, :boolean, null: false
      add :cause, :text
      add :legacy, :map, null: false
      add :walk, :map, null: false
      add :budgets, {:array, :map}, null: false, default: []
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:admission_shadow_events, [:at])
  end
end
