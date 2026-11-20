defmodule Wardmast.Screenshots.CaptureRecord do
  @moduledoc """
  One screenshot capture attempt for a ticket (`screenshot_captures`, bd-8qj1sa). Written by
  `Wardmast.Screenshots.Captures`.

  `state`:

    * `"running"` — the capture is in flight;
    * `"captured"` — pairs were produced;
    * `"skipped"` — nothing was booted: the diff misses `ui_paths`, the worker declared a skip, or
      the host has no sandbox. Does not count against `max_captures_per_ticket`;
    * `"failed"` — the capture ended in a `Wardmast.Screenshots.Capture.Failure` (`failure_code`);
    * `"superseded"` — a newer head arrived first and this attempt was cancelled.

  `plan_hash` and `config_hash` are what a later head compares against to decide whether a
  re-capture is worth it.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(running captured skipped failed superseded)

  schema "screenshot_captures" do
    field :task_id, :string
    field :workspace_id, :string
    field :head_sha, :string
    field :base_sha, :string
    field :plan_hash, :string
    field :config_hash, :string
    field :state, :string
    field :reason, :string
    field :failure_code, :string
    field :pair_count, :integer
    field :out_dir, :string
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "The states a row can be in."
  @spec states() :: [String.t()]
  def states, do: @states
end
