defmodule Wardmast.Preview.Lease do
  @moduledoc """
  One app preview, and the port lease it holds (`preview_leases`).

  Keyed by `(repo, task_id)`; `port` is unique, so a port can be held by at most
  one preview. `port` is nil once the preview has stopped or failed — the lease
  is released but a failed row stays so its error and log are readable.

  `status`: `"starting"` (checkout / setup / waiting for ready), `"running"`,
  `"failed"`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "preview_leases" do
    field :repo, :string
    field :task_id, :string
    field :workspace_id, :string
    field :port, :integer
    field :status, :string
    field :os_pid, :integer
    field :url, :string
    field :log_path, :string
    field :checkout_path, :string
    field :checkout_kind, :string
    field :checkout_note, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :touched_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{}
end
