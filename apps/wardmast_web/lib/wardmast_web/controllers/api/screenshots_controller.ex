defmodule WardmastWeb.Api.ScreenshotsController do
  @moduledoc """
  `POST /api/issues/:task_id/screenshots/check` (bd-adrym0): the `arb done` screenshots-plan check
  (`Wardmast.Screenshots.TaskCheck`), asked early. The CLI twin is `ward screenshots check`, the
  MCP twin `screenshots_plan_check`. Own task for a worker (`ApiPolicy` `:own_task`).
  """

  use WardmastWeb, :controller

  alias Wardmast.Screenshots.TaskCheck

  action_fallback(WardmastWeb.Api.FallbackController)

  def check(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    with {:ok, result} <- TaskCheck.run(task_id) do
      json(conn, result)
    end
  end

  def check(_conn, _params),
    do: {:error, {:invalid_request, "task_id path parameter is required"}}
end
