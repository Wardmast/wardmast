defmodule WardmastWeb.Api.AttachmentController do
  @moduledoc """
  Ticket attachments over REST (`Wardmast.Attachments`, bd-5hlegn) — the twin of
  the `ticket_attach` / `ticket_attachment_list` MCP tools.

    * `GET  /api/issues/:task_id/attachments` — the ticket's attachments, oldest
      first: metadata and a dashboard `url`, never bytes
    * `POST /api/issues/:task_id/attachments` — JSON body `data` (the image,
      base64) plus optional `filename`, `caption`, `role`, `shot_id`, `viewport`,
      `theme`. 201 with the attachment; 422 for a bad or oversize image; 409 when
      a ticket or store ceiling is reached.

  Access is `WardmastWeb.ApiPolicy` `:own_task`: a coordinator, or a worker on its
  own ticket. A token bound to one workspace reaches only that workspace's
  tickets (another's is a 404). The `source` is derived from the token's tier and
  is not a parameter: a body naming one is refused.
  """

  use WardmastWeb, :controller

  alias Wardmast.Attachments
  alias Wardmast.MCP.Tools.Attachment, as: AttachmentTool
  alias Wardmast.Tasks.Issue
  alias WardmastWeb.Api.WorkspaceParam

  action_fallback(WardmastWeb.Api.FallbackController)

  @fields ~w(filename caption role shot_id viewport theme)

  def index(conn, %{"task_id" => task_id} = params) do
    with {:ok, issue} <- fetch_issue(conn, task_id, params) do
      json(conn, %{
        task_id: issue.id,
        attachments: Enum.map(Attachments.list(issue.id), &Attachments.serialize/1)
      })
    end
  end

  def create(conn, %{"task_id" => task_id} = params) do
    with :ok <- reject_source(params),
         {:ok, issue} <- fetch_issue(conn, task_id, params),
         {:ok, data} <- Attachments.decode_base64(params["data"]),
         {:ok, att} <- Attachments.create(issue, attrs(data, params), source: source(conn)) do
      conn |> put_status(:created) |> json(%{attachment: Attachments.serialize(att)})
    end
  end

  defp fetch_issue(conn, task_id, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, %Issue{} = issue} <- Ash.get(Issue, task_id),
         true <- is_nil(ws_id) or issue.workspace_id == ws_id do
      {:ok, issue}
    else
      _ -> {:error, :not_found}
    end
  end

  defp reject_source(params) do
    if Map.has_key?(params, "source"),
      do: {:error, {:invalid, "`source` is set by the server, not by the caller"}},
      else: :ok
  end

  defp attrs(data, params) do
    for key <- @fields, Map.has_key?(params, key), into: %{data: data} do
      {String.to_existing_atom(key), params[key]}
    end
  end

  defp source(conn) do
    case conn.assigns[:mcp_scope] do
      %Wardmast.MCP.Scope{} = scope -> AttachmentTool.source(scope)
      _ -> "coordinator"
    end
  end
end
