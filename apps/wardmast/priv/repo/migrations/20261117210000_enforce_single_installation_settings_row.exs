defmodule Arbiter.Repo.Migrations.EnforceSingleInstallationSettingsRow do
  @moduledoc """
  `installation_settings` is a singleton, but nothing stopped a second row (two
  concurrent first writes each saw an empty table and each inserted), after which
  `Settings` read whichever row SQLite returned first while writes hit another.

  Collapses any duplicates to the earliest-created row (the one reads have most
  likely been returning, ties by rowid) and adds a unique index on a constant
  expression, so a second row is refused by the database.
  """

  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM installation_settings
    WHERE rowid NOT IN (
      SELECT rowid FROM installation_settings ORDER BY created_at ASC, rowid ASC LIMIT 1
    )
    """)

    execute(
      "CREATE UNIQUE INDEX installation_settings_singleton_index ON installation_settings ((1))"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS installation_settings_singleton_index")
  end
end
