defmodule Wardmast.Attachments.Attachment do
  @moduledoc """
  One image attached to a ticket (`ticket_attachments`). The bytes are on disk
  (`Wardmast.Attachments`); this row is the metadata and provenance.

  `source` says who wrote it: `"worker"`, `"coordinator"` or `"operator"` for a
  hand attach, `"arbiter-capture"` for the capture pass. Only Arbiter writes
  the last (`Wardmast.Attachments.create_capture/2`), so what a reader sees under
  that source was captured from the app, never supplied by a worker.

  `role` (`"before"` / `"after"`) with `shot_id`, `viewport` and `theme` keys a
  before/after pair for the ticket page. `pruned_at` is set once retention
  deleted the blob; the row keeps its hash and provenance.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "ticket_attachments" do
    field :task_id, :string
    field :workspace_id, :string
    field :filename, :string
    field :caption, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :sha256, :string
    field :source, :string
    field :role, :string
    field :shot_id, :string
    field :viewport, :string
    field :theme, :string
    field :capture_id, :string
    field :head_sha, :string
    field :base_sha, :string
    field :pruned_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{}
end
