defmodule Wardmast.MCP.Tools.Attachment do
  @moduledoc """
  `Wardmast.MCP.Tools` handlers for ticket attachments (`Wardmast.Attachments`,
  bd-5hlegn): `ticket_attach` and `ticket_attachment_list`, the MCP twins of
  `POST|GET /api/issues/:id/attachments`.

  Scoping is the same as every ticket tool: a worker reaches its **own** task
  only (`Tools.resolve_task_id/3`), a coordinator any ticket in the workspaces it
  may reach (`Tools.fetch_task/3` reports another workspace's id as not-found, so
  existence does not leak). The attachment's `source` comes from the caller's
  tier (`worker`, `coordinator`, or `operator` over the operator socket) and is
  **never an argument**: a client cannot claim to be the capture pass.
  """

  alias Wardmast.Attachments
  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools

  @doc "Attach an image (base64 `data`) to a ticket."
  @spec ticket_attach(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_attach(%Scope{} = scope, args) do
    with :ok <- reject_source(args),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "id"),
         {:ok, issue} <- Tools.fetch_task(scope, args, task_id),
         {:ok, data} <- Attachments.decode_base64(args["data"]),
         {:ok, att} <- attach(issue, data, args, source(scope)) do
      {:ok, %{attachment: Attachments.serialize(att)}}
    end
  end

  @doc "A ticket's attachments, oldest first: metadata and a dashboard URL, never bytes."
  @spec ticket_attachment_list(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_attachment_list(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "id"),
         {:ok, issue} <- Tools.fetch_task(scope, args, task_id) do
      {:ok,
       %{
         task_id: issue.id,
         attachments: Enum.map(Attachments.list(issue.id), &Attachments.serialize/1)
       }}
    end
  end

  @doc false
  @spec source(Scope.t()) :: String.t()
  def source(%Scope{tier: :worker}), do: "worker"
  def source(%Scope{tier: :coordinator, operator: true}), do: "operator"
  def source(%Scope{}), do: "coordinator"

  defp reject_source(args) do
    if Map.has_key?(args, "source"),
      do: {:error, {:invalid, "`source` is set by the server, not by the caller"}},
      else: :ok
  end

  defp attach(issue, data, args, source) do
    attrs =
      for key <- ~w(filename caption role shot_id viewport theme),
          Map.has_key?(args, key),
          into: %{data: data},
          do: {String.to_existing_atom(key), args[key]}

    Attachments.create(issue, attrs, source: source)
  end
end
