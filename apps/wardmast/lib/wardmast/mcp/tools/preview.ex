defmodule Wardmast.MCP.Tools.Preview do
  @moduledoc """
  `Wardmast.MCP.Tools` handlers for app previews (`Wardmast.Preview`):
  `preview_start` / `preview_stop` / `preview_list` / `preview_logs` — the MCP
  twins of `ward preview start|stop|list|logs`.

  Coordinator-only: a preview runs the repo's configured command in a checkout
  on the primary. Every tool resolves the ticket through
  `Wardmast.MCP.Tools.fetch_task/3`, so a workspace-bound scope reaches only its
  own tickets and another workspace's id is reported not-found.
  """

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Params
  alias Wardmast.Preview

  @failed_tail_lines 40

  @doc "Start a preview of `task_id`; `wait` blocks until it is ready or failed."
  @spec preview_start(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def preview_start(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, wait?} <- Params.fetch_bool(args, "wait", false),
         {:ok, row} <- run(Preview.start(task_id, repo_opts(args) ++ [wait: wait?])) do
      {:ok, %{preview: render(row)}}
    end
  end

  @doc "Stop `task_id`'s preview, killing its process group and freeing its port."
  @spec preview_stop(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def preview_stop(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, rows} <- run(Preview.stop(task_id, repo_opts(args))) do
      {:ok, %{task_id: task_id, stopped: Enum.map(rows, &Preview.serialize/1)}}
    end
  end

  @doc """
  Every preview in scope, or — with `task_id` — that ticket's (a failed one
  carries its `log_tail`).
  """
  @spec preview_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def preview_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      case args["task_id"] do
        id when is_binary(id) and id != "" -> show_one(scope, args, id, ws_id)
        _ -> {:ok, %{previews: list_all(ws_id), workspace_id: ws_id}}
      end
    end
  end

  defp list_all(ws_id) do
    opts = if ws_id, do: [workspace_id: ws_id], else: []
    Enum.map(Preview.list(opts), &Preview.serialize/1)
  end

  defp show_one(scope, args, id, ws_id) do
    with {:ok, _task} <- Tools.fetch_task(scope, args, id) do
      case Preview.get(id, repo_opts(args)) do
        nil -> {:error, {:not_found, "no preview for task #{id}"}}
        row -> {:ok, %{preview: render(row), workspace_id: ws_id}}
      end
    end
  end

  @doc "The tail (`lines`) or the part after `offset` of a preview's log."
  @spec preview_logs(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def preview_logs(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      opts =
        repo_opts(args) ++
          Enum.reject(
            [lines: pos_int(args["lines"]), offset: pos_int(args["offset"])],
            fn {_, v} -> is_nil(v) end
          )

      case Preview.logs(task_id, opts) do
        {:ok, log} -> {:ok, %{task_id: task_id, content: log.content, offset: log.offset}}
        {:error, :not_found} -> {:error, {:not_found, "no log for task #{task_id}'s preview"}}
      end
    end
  end

  defp run({:ok, _} = ok), do: ok
  defp run({:error, reason}), do: {:error, Preview.error(reason)}

  defp render(row) do
    base = Preview.serialize(row)

    with "failed" <- row.status,
         {:ok, %{content: tail}} <-
           Preview.logs(row.task_id, repo: row.repo, lines: @failed_tail_lines) do
      Map.put(base, :log_tail, tail)
    else
      _ -> base
    end
  end

  defp repo_opts(%{"repo" => repo}) when is_binary(repo) and repo != "", do: [repo: repo]
  defp repo_opts(_), do: []

  defp pos_int(raw) do
    case Params.integer(raw) do
      {:ok, n} when n >= 0 -> n
      _ -> nil
    end
  end
end
