defmodule Wardmast.MCP.Tools.PermissionRequest do
  @moduledoc """
  `Wardmast.MCP.Tools` handler for `permission_request` (G15a, bd-dvqdcc;
  `docs/design/guardrail-profiles.md` §5.6): a worker asks for a permission it
  found it needs. Worker tier only, for its own task only.

  It records the request and tells whoever may grant it
  (`Wardmast.Tasks.PermissionRequest`). It never grants: the answer is always
  "recorded, not granted", and nothing about the run's reach changes.
  """

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Tasks.PermissionRequest

  @status "recorded, not granted"

  @spec permission_request(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def permission_request(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         {:ok, result} <-
           PermissionRequest.submit(issue, Map.get(args, "permission"), Map.get(args, "reason"),
             actor: Wardmast.PaperTrail.actor_label(scope)
           ) do
      {:ok,
       %{
         recorded: true,
         granted: false,
         status: @status,
         permission: result.permission,
         grant_by: Atom.to_string(result.grant_by),
         already_requested: result.already_requested,
         message:
           "#{@status}. Carry on without #{result.permission}, or stop and report the " <>
             "affected acceptance criteria as unmet; the #{result.grant_by} decides. " <>
             "Nothing about this run changed."
       }}
    end
  end
end
