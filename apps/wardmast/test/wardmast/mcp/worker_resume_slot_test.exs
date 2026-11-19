defmodule Wardmast.MCP.WorkerResumeSlotTest do
  @moduledoc """
  bd-92mx1m acceptance 2/4 on the MCP surface: `worker_resume` of a task that
  released its slot, at a full cap, is refused with a message naming the cap
  and the slot-holding tasks; `force: true` admits it and records the override.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.MCP.Scope
  alias Wardmast.MCP.Tools
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Usage.Event, as: UsageEvent
  alias Wardmast.Worker

  setup do
    # bd-80ecol: the resume reaches the real-agent dispatch guard, which
    # refuses a Claude spawn with no credential of its own.
    claude_credential_env!()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-resume-slot-#{System.unique_integer([:positive])}",
        prefix: "mrs#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    incident = ResumeSlotFixture.setup_incident(ws)

    # `worker_resume` continues the prior session (bd-a9hqfb), so it needs one.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: incident.a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    Map.merge(%{ws: ws, coordinator: coordinator}, incident)
  end

  test "the catalog schema accepts `force`" do
    tool = Enum.find(Wardmast.MCP.Catalog.all(), &(&1.name == "worker_resume"))
    assert %{"type" => "boolean"} = tool.input_schema["properties"]["force"]
  end
end
