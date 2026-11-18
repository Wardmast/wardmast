defmodule WardmastWeb.Api.PreviewController do
  @moduledoc """
  REST endpoints for app previews (`Wardmast.Preview`) — the transport behind
  `ward preview start|stop|list|logs`.

    * `GET  /api/previews` — every preview (`?workspace=` scopes)
    * `POST /api/previews` — start one: `task_id`, optional `repo`, `wait`
    * `GET  /api/previews/:task_id` — one preview (`?repo=`); a failed one
      carries its `log_tail`
    * `GET  /api/previews/:task_id/logs` — `?lines=N` (the last N) or
      `?offset=B` (everything after byte B, for following); `content`, `offset`
    * `POST /api/previews/:task_id/stop` — stop it, free its port

  Coordinator-only (`WardmastWeb.ApiPolicy`): a preview runs the repo's
  configured command. A token bound to a workspace reaches only its tickets.
  """

  use WardmastWeb, :controller

  alias Wardmast.Params
  alias Wardmast.Preview
  alias WardmastWeb.Api.WorkspaceParam

  action_fallback(WardmastWeb.Api.FallbackController)

  @failed_tail_lines 40

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      opts = if ws_id, do: [workspace_id: ws_id], else: []

      json(conn, %{
        previews: Enum.map(Preview.list(opts), &Preview.serialize/1),
        workspace_id: ws_id
      })
    end
  end

  def create(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    with :ok <- authorize(conn, task_id),
         {:ok, wait?} <- params |> Params.fetch_bool("wait", false) |> Params.to_rest(),
         {:ok, row} <- run(Preview.start(task_id, start_opts(params, wait?))) do
      conn |> put_status(:created) |> json(%{preview: with_log_tail(row)})
    end
  end

  def create(_conn, _params), do: {:error, {:invalid_request, "task_id is required"}}

  def show(conn, %{"task_id" => task_id} = params) do
    with :ok <- authorize(conn, task_id) do
      case Preview.get(task_id, repo_opts(params)) do
        nil -> {:error, :not_found}
        row -> json(conn, %{preview: with_log_tail(row)})
      end
    end
  end

  def logs(conn, %{"task_id" => task_id} = params) do
    with :ok <- authorize(conn, task_id),
         {:ok, opts} <- log_opts(params),
         {:ok, log} <- Preview.logs(task_id, opts ++ repo_opts(params)) do
      json(conn, %{task_id: task_id, content: log.content, offset: log.offset})
    else
      {:error, :not_found} -> {:error, {:not_found, "no log for that preview"}}
      other -> other
    end
  end

  def stop(conn, %{"task_id" => task_id} = params) do
    with :ok <- authorize(conn, task_id),
         {:ok, rows} <- run(Preview.stop(task_id, repo_opts(params))) do
      json(conn, %{task_id: task_id, stopped: Enum.map(rows, &Preview.serialize/1)})
    end
  end

  defp run({:ok, _} = ok), do: ok
  defp run({:error, reason}), do: {:error, Preview.error(reason)}

  # A failed preview shows its log tail, so the caller sees why.
  defp with_log_tail(row) do
    base = Preview.serialize(row)

    if row.status == "failed" do
      case Preview.logs(row.task_id, repo: row.repo, lines: @failed_tail_lines) do
        {:ok, %{content: tail}} -> Map.put(base, :log_tail, tail)
        _ -> base
      end
    else
      base
    end
  end

  defp start_opts(params, wait?) do
    [wait: wait?] ++ repo_opts(params)
  end

  defp repo_opts(%{"repo" => repo}) when is_binary(repo) and repo != "", do: [repo: repo]
  defp repo_opts(_), do: []

  defp log_opts(params) do
    with {:ok, lines} <- int(params["lines"], "lines"),
         {:ok, offset} <- int(params["offset"], "offset") do
      {:ok, Enum.reject([lines: lines, offset: offset], fn {_, v} -> is_nil(v) end)}
    end
  end

  defp int(raw, _name) when raw in [nil, ""], do: {:ok, nil}

  defp int(raw, name) do
    case Params.integer(raw) do
      {:ok, n} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "#{name} must be a non-negative integer"}}
    end
  end

  # A workspace-bound token reaches only its own tickets; an unknown ticket and
  # another workspace's look the same.
  defp authorize(conn, task_id) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, %{}, :read) do
      if is_nil(ws_id) or Preview.ticket_workspace_id(task_id) == ws_id,
        do: :ok,
        else: {:error, :not_found}
    end
  end
end
