defmodule Wardmast.Screenshots.TaskCheck do
  @moduledoc """
  `ward screenshots check` / MCP `screenshots_plan_check` / `POST /api/issues/:id/screenshots/check`:
  the same plan check the `arb done` commit gate runs (`Wardmast.Screenshots.PlanCheck`), asked
  early by a worker about its own task, so a missing or invalid plan is fixed before `arb done`.

  Read-only: it never stores the plan or touches git config; only the commit gate does that.
  """

  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.PlanCheck
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker

  @type error :: {:conflict | :not_found | :invalid, String.t()}

  @spec run(String.t()) :: {:ok, map()} | {:error, error()}
  def run(task_id) when is_binary(task_id) do
    with {:ok, issue} <- fetch(Issue, task_id, "task #{task_id} not found"),
         {:ok, runner} <- runner(task_id) do
      workspace = load_workspace(issue.workspace_id)
      respond(Config.resolve(workspace, issue.repo), runner)
    end
  end

  defp respond(:none, _runner),
    do:
      {:ok,
       %{status: "not_configured", ok: true, messages: ["this repo has no screenshots config"]}}

  defp respond({:error, errors}, _runner),
    do:
      {:error,
       {:invalid, "the screenshots config does not validate: " <> Enum.join(errors, "; ")}}

  defp respond({:ok, config}, %{worktree: worktree, target: target}) do
    case PlanCheck.check(config, worktree, target) do
      :not_applicable ->
        {:ok,
         %{
           status: "not_applicable",
           ok: true,
           messages: ["the diff does not touch ui_paths: no plan needed"]
         }}

      {:ok, %{sha: nil}} ->
        {:ok,
         %{
           status: "no_plan",
           ok: true,
           messages: ["no plan (plan_required is false): default_routes will be shot"]
         }}

      {:ok, %{skip: skip, sha: sha}} when is_binary(skip) ->
        {:ok, %{status: "skip", ok: true, sha: sha, messages: ["valid skip: #{skip}"]}}

      {:ok, %{sha: sha}} ->
        {:ok, %{status: "ok", ok: true, sha: sha, messages: ["plan is valid"]}}

      {:error, messages} ->
        {:ok, %{status: "invalid", ok: false, messages: messages}}
    end
  end

  defp fetch(resource, id, message) do
    case Ash.get(resource, id) do
      {:ok, record} when not is_nil(record) -> {:ok, record}
      _ -> {:error, {:not_found, message}}
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(id) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp runner(task_id) do
    case Worker.test_runner(task_id) do
      {:ok, runner} ->
        {:ok, runner}

      {:error, :no_worker} ->
        {:error, {:conflict, "no live worker for task #{task_id}: there is no worktree to check"}}

      {:error, :no_worktree} ->
        {:error, {:conflict, "task #{task_id}'s run has no worktree to check"}}
    end
  end
end
