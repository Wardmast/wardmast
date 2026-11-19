defmodule Arbiter.Repo.Migrations.DropSchedulerAdmission do
  @moduledoc """
  DC12 (bd-b3u00u): the `legacy` and `shadow` admission modes are retired, so
  admission is always the budget walk's and there is nothing left to select.

    * `installation_settings.scheduler_admission` — the install-wide mode.
    * `provider_accounts.admission` — the per-account override (O11).

  Rollback re-adds both columns, empty: a rolled-back build reads NULL as
  `legacy`, which is the mode the old code defaults to.
  """

  use Ecto.Migration

  def up do
    alter table(:installation_settings) do
      remove :scheduler_admission
    end

    alter table(:provider_accounts) do
      remove :admission
    end
  end

  def down do
    alter table(:installation_settings) do
      add :scheduler_admission, :string
    end

    alter table(:provider_accounts) do
      add :admission, :text, null: true
    end
  end
end
