defmodule Wardmast.MCP.Tools.ScreenshotsPlanCheck do
  @moduledoc """
  `Wardmast.MCP.Tools` handler for `screenshots_plan_check`: a worker asks whether its
  `.arbiter/screenshots.json` would pass the `arb done` commit gate. Worker tier, own task only;
  the logic is `Wardmast.Screenshots.TaskCheck`.
  """

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Screenshots.TaskCheck

  @spec screenshots_plan_check(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def screenshots_plan_check(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "id") do
      TaskCheck.run(task_id)
    end
  end
end
