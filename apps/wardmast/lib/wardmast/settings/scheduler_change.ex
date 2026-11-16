defmodule Wardmast.Settings.SchedulerChange do
  @moduledoc """
  One audit row per board scheduler pause or resume (bd-cl6zjn): `paused` is
  the state it moved to, `actor` who asked, `surface` where from (`dashboard`,
  `cli`, `api`, `mcp`), `at` when. Append-only; written by
  `Wardmast.Board.Autopilot` through `Wardmast.Settings.record_scheduler_change/3`.
  """

  use Ash.Resource,
    otp_app: :wardmast,
    domain: Wardmast.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "scheduler_changes"
    repo Wardmast.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:paused, :actor, :surface]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :paused, :boolean, allow_nil?: false, public?: true
    attribute :actor, :string, public?: true
    attribute :surface, :string, public?: true

    create_timestamp :at
  end
end
