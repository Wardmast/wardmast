defmodule WardmastWeb.PairEntryPointTest do
  @moduledoc """
  bd-7p6a9o, acceptance 6 (the ticket-page half): **Pair on this ticket** on
  the ticket page launches — or reopens — the ticket's pair session and opens
  it in the dock; while it lives, the page offers **Done** and **End** in its
  place and no Dispatch.
  """
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Wardmast.LifecycleFixtures
  import WardmastWeb.TaskDetailLiveHelpers

  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Test.NoopRunner
  alias Wardmast.Worker

  @async_timeout WardmastWeb.Test.Timing.scale(30_000)

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)

    Wardmast.Test.SessionEnv.sandbox("pair-entry")
    # The click launches inside the LiveView process, so the runner stub comes
    # from application config.
    Wardmast.DataCase.put_app_env(:wardmast, :sessions_runner, NoopRunner)
    git = GitFixture.forge_and_checkout()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-entry-ws-#{System.unique_integer([:positive])}",
        prefix: "pen#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
        }
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "pair on me",
        acceptance: "- done",
        workspace_id: ws.id,
        repo: "widget",
        issue_type: :feature
      })

    {:ok, issue: put_state!(issue, :queued)}
  end

  test "a Ready ticket offers Pair", %{conn: conn, issue: issue} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")

    assert has_element?(view, "#task-pair")
    refute has_element?(view, "#task-pair-done")
    refute has_element?(view, "#task-pair-end")
  end

  test "a merging or closed ticket does not", %{conn: conn, issue: issue} do
    merging = put_state!(issue, :merging)
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{merging.id}")
    refute has_element?(view, "#task-pair")
  end

  test "a click launches the pair session, opens it in the dock, and swaps in Done and End", %{
    conn: conn,
    issue: issue
  } do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")
    dock = find_live_child(view, "session-dock")

    render_click(element(view, "#task-pair"))

    assert {:ok, session} = Pair.live_session(issue.id)
    assert session.kind == :pair
    assert has_element?(dock, ~s(#session-dock-title-#{session.id}[aria-expanded="true"]))

    assert has_element?(view, "#task-pair-done")
    assert has_element?(view, "#task-pair-end")
    assert has_element?(view, "#task-pair-claim")
    refute has_element?(view, "#task-pair")
    assert has_element?(view, "#toast-info", "Launched a pair session")
  end

  test "End ends the session, keeps the worktree and offers Pair again", %{
    conn: conn,
    issue: issue
  } do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")
    render_click(element(view, "#task-pair"))
    {:ok, session} = Pair.live_session(issue.id)

    render_click(element(view, "#task-pair-end"))

    assert Pair.live_session(issue.id) == :none
    assert File.dir?(session.cwd)
    assert has_element?(view, "#task-pair")
    refute has_element?(view, "#task-pair-done")
  end

  test "Done with nothing committed reports the refusal and keeps the session", %{
    conn: conn,
    issue: issue
  } do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{issue.id}")
    render_click(element(view, "#task-pair"))

    render_click(element(view, "#task-pair-done"))
    render_async(view, @async_timeout)

    assert has_element?(view, "#toast-error", "no commits")
    assert {:ok, _still_live} = Pair.live_session(issue.id)
    assert has_element?(view, "#task-pair-done")
  end
end
