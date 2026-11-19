defmodule WardmastProFake.Values do
  @moduledoc false
  @behaviour Wardmast.Extension.Value

  @impl true
  def description, do: "fake"
end

defmodule WardmastProFake.ValueExtension do
  @moduledoc false
  @behaviour Wardmast.Extension

  @impl true
  def contributions do
    [
      {:issue_type, "spike", WardmastProFake.Values},
      {:session_kind, "review_pane", WardmastProFake.Values},
      {:tracker, "acme_tracker", Wardmast.Trackers.None},
      {:session_provider, "acme_cli", Wardmast.Sessions.Provider.ClaudeCode}
    ]
  end
end

defmodule Wardmast.Extensions.RegisteredAtomTest do
  # Swaps the install-global registry.
  use Wardmast.DataCase, async: false

  alias Wardmast.Extensions
  alias Wardmast.Sessions.Session
  alias Wardmast.Tasks.Issue

  setup do
    on_exit(fn -> Extensions.load!() end)
    {:ok, ws} = Ash.create(Wardmast.Tasks.Workspace, %{name: "reg-ws", prefix: "reg"})
    %{ws: ws}
  end

  test "core values behave as before", %{ws: ws} do
    for type <- ~w(task research bug feature epic chore decision)a do
      assert {:ok, %{issue_type: ^type}} =
               Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: type})
    end

    assert {:ok, %{issue_type: :feature, tracker_type: :none}} =
             Ash.create(Issue, %{title: "t", workspace_id: ws.id})

    assert Issue.issue_types() == ~w(task research bug feature epic chore decision)a
    assert Issue.tracker_types() == ~w(none jira shortcut linear github gitlab)a
    assert Session.kinds() == ~w(coordinator login pair)a
    assert Session.providers() == ~w(claude_code agy)a
  end

  test "an unregistered value is rejected with a clear error", %{ws: ws} do
    assert {:error, error} =
             Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :spike})

    assert Exception.message(error) =~ "is not a registered issue_type"
    assert Exception.message(error) =~ "feature"

    assert {:error, error} =
             Ash.create(Issue, %{title: "t", workspace_id: ws.id, tracker_type: "acme_tracker"})

    assert Exception.message(error) =~ "is not a registered tracker"
  end

  test "an extension adds values without a core change, and rows persist and reload", %{ws: ws} do
    Extensions.load!([WardmastProFake.ValueExtension])

    assert {:ok, issue} =
             Ash.create(Issue, %{
               title: "t",
               workspace_id: ws.id,
               issue_type: :spike,
               tracker_type: "acme_tracker"
             })

    assert {:ok, %{issue_type: :spike, tracker_type: :acme_tracker}} = Ash.get(Issue, issue.id)
    assert :spike in Issue.issue_types()
    assert :acme_tracker in Issue.tracker_types()
    assert :review_pane in Session.kinds()
    assert :acme_cli in Session.providers()

    assert {:ok, %{kind: :review_pane, provider: :acme_cli}} =
             Ash.create(Session, %{name: "s-reg", kind: :review_pane, provider: :acme_cli})
  end

  test "a row whose extension was uninstalled still loads", %{ws: ws} do
    Extensions.load!([WardmastProFake.ValueExtension])
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :spike})
    Extensions.load!()

    assert {:ok, %{issue_type: :spike}} = Ash.get(Issue, issue.id)

    assert {:error, _} =
             Ash.create(Issue, %{title: "t2", workspace_id: ws.id, issue_type: :spike})
  end
end
