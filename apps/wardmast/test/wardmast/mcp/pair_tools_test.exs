defmodule Wardmast.MCP.PairToolsTest do
  @moduledoc """
  bd-7p6a9o: the pair session's MCP surface — `pair_open`, `pair_done` and
  `pair_end`, the twins of `ward pair <ticket>`, `ward pair done <ticket>` and
  `ward pair end <ticket>`.

  Opening and ending are the coordinator's (and so the operator's) calls.
  `pair_done` is also the pair session's own: its ticket-scoped token may
  finish the session it belongs to, and no other worker token may.
  """
  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures, only: [put_state!: 2]

  alias Wardmast.MCP.Catalog
  alias Wardmast.MCP.Scope
  alias Wardmast.Sessions
  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Test.GitFixture
  alias Wardmast.Test.SessionEnv
  alias Wardmast.Test.SessionRunnerStub

  setup do
    SessionEnv.sandbox("pair-mcp")
    SessionRunnerStub.reset()
    put_app_env(:wardmast, :sessions_runner, SessionRunnerStub)
    git = GitFixture.forge_and_checkout()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pair-mcp-#{System.unique_integer([:positive])}",
        prefix: "pm#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
        }
      })

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Make widgets faster",
        acceptance: "- faster",
        workspace_id: ws.id,
        repo: "widget",
        issue_type: :feature
      })

    %{
      ws: ws,
      issue: put_state!(issue, :queued),
      coordinator: %Scope{tier: :coordinator, can_dispatch: false},
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: issue.id},
      refine: %Scope{tier: :refine, workspace_id: ws.id, issue_id: issue.id}
    }
  end

  defp call(scope, tool, args), do: Catalog.call(scope, tool, args)

  describe "the catalog" do
    test "pair_open and pair_end are coordinator tools; pair_done is also the pair's own" do
      assert {:ok, %{tiers: [:coordinator]}} = Catalog.fetch("pair_open")
      assert {:ok, %{tiers: [:coordinator]}} = Catalog.fetch("pair_end")
      assert {:ok, %{tiers: tiers}} = Catalog.fetch("pair_done")
      assert Enum.sort(tiers) == [:coordinator, :worker]
    end
  end

  describe "pair_open" do
    test "opens the ticket's pair session, and a second call reopens it", ctx do
      assert {:ok, opened} = call(ctx.coordinator, "pair_open", %{"id" => ctx.issue.id})
      assert opened.reopened == false
      assert opened.ticket_id == ctx.issue.id
      assert opened.name == "Pair #{ctx.issue.id}: Make widgets faster"
      assert File.dir?(opened.worktree)

      assert {:ok, again} = call(ctx.coordinator, "pair_open", %{"id" => ctx.issue.id})
      assert again.reopened == true
      assert again.session_id == opened.session_id
    end

    test "a ticket that cannot be paired on is refused with the reason", ctx do
      merging = put_state!(ctx.issue, :merging)

      assert {:tool_error, message, _type} =
               call(ctx.coordinator, "pair_open", %{"id" => merging.id})

      assert message =~ "cannot be paired on"
    end

    test "a refine session or a worker cannot open one", ctx do
      assert {:rpc_error, -32003, _} = call(ctx.refine, "pair_open", %{"id" => ctx.issue.id})
      assert {:rpc_error, -32003, _} = call(ctx.worker, "pair_open", %{"id" => ctx.issue.id})
      assert Pair.live_session(ctx.issue.id) == :none
    end
  end

  describe "pair_end" do
    test "ends the session without Done and leaves the worktree", ctx do
      {:ok, opened} = call(ctx.coordinator, "pair_open", %{"id" => ctx.issue.id})

      assert {:ok, ended} = call(ctx.coordinator, "pair_end", %{"id" => ctx.issue.id})
      assert ended.session_id == opened.session_id
      assert ended.status == :ended
      assert Pair.live_session(ctx.issue.id) == :none
      assert File.dir?(opened.worktree)
    end

    test "with no live pair session, says so", ctx do
      assert {:tool_error, message, _} =
               call(ctx.coordinator, "pair_end", %{"id" => ctx.issue.id})

      assert message =~ "no live pair session"
    end
  end

  describe "pair_done" do
    test "the pair session's own token may run Done (here the commit gate refuses it)", ctx do
      {:ok, %{session: session}} = Pair.open(ctx.issue, runner: SessionRunnerStub)
      File.write!(Path.join(session.cwd, "loose.txt"), "uncommitted\n")
      {:ok, own} = Scope.from_token(Sessions.mint_mcp_token(session))

      assert {:tool_error, message, _} = call(own, "pair_done", %{})
      assert message =~ "uncommitted"
      assert {:ok, _still_live} = Pair.live_session(ctx.issue.id)
    end

    test "any other worker token is refused", ctx do
      {:ok, _} = Pair.open(ctx.issue, runner: SessionRunnerStub)

      assert {:rpc_error, -32003, message} = call(ctx.worker, "pair_done", %{})
      assert message =~ "pair session"
      assert {:ok, _still_live} = Pair.live_session(ctx.issue.id)
    end

    test "the coordinator may run it; nothing committed is refused", ctx do
      {:ok, _} = Pair.open(ctx.issue, runner: SessionRunnerStub)

      assert {:tool_error, message, _} =
               call(ctx.coordinator, "pair_done", %{"id" => ctx.issue.id})

      assert message =~ "no commits"
    end
  end
end
