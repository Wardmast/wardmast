defmodule Wardmast.Workflows.PRPatrol.AuthorScopeTest do
  @moduledoc """
  bd-cwigjh / #1550: who PRPatrol may act on, and the push guard that stops a
  follow-up worker pushing to a branch whose PR author is out of scope.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Events.Record
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Workflows.PRPatrol.AuthorScope

  require Ash.Query

  @stub Wardmast.Mergers.Github.HTTP

  defp workspace!(patrol_config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "scope-#{System.unique_integer([:positive])}",
        prefix: "sc#{System.unique_integer([:positive])}",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "owner",
              "repo" => "repo",
              "credentials_ref" => "env:GITHUB_TOKEN"
            }
          },
          "pr_patrol" => patrol_config
        }
      })

    ws
  end

  defp follow_up!(ws, source_pr) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "PR ##{source_pr}: needs follow-up",
        workspace_id: ws.id,
        issue_type: :research,
        source_pr: source_pr
      })

    task
  end

  defp stub_pr_author(number, author) do
    Req.Test.stub(@stub, fn conn ->
      path = conn.request_path
      json = fn body -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(body) end

      cond do
        path == "/repos/owner/repo/pulls/#{number}" ->
          json.(%{
            "number" => number,
            "state" => "open",
            "title" => "t",
            "user" => author && %{"login" => author},
            "head" => %{"sha" => "abc", "ref" => "feature"},
            "base" => %{"ref" => "main"}
          })

        String.ends_with?(path, "/check-runs") ->
          json.(%{"check_runs" => []})

        true ->
          json.([])
      end
    end)
  end

  setup do
    prior = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token-scope")

    on_exit(fn ->
      if prior, do: System.put_env("GITHUB_TOKEN", prior), else: System.delete_env("GITHUB_TOKEN")
    end)

    :ok
  end

  describe "Workspace.pr_patrol_author_scope/1" do
    test "unset, empty, blank and malformed all mean :own" do
      for value <- [nil, [], [""], "   ", 42, %{}] do
        ws = %Workspace{config: %{"pr_patrol" => %{"author_logins" => value}}}
        assert Workspace.pr_patrol_author_scope(ws) == :own
      end

      assert Workspace.pr_patrol_author_scope(%Workspace{config: %{}}) == :own
    end

    test "\"*\" and a list containing it mean :all" do
      for value <- ["*", ["*"], ["alice", "*"], " * "] do
        ws = %Workspace{config: %{"pr_patrol" => %{"author_logins" => value}}}
        assert Workspace.pr_patrol_author_scope(ws) == :all
      end
    end

    test "a login list is {:logins, _}; a single string is one login" do
      ws = %Workspace{config: %{"pr_patrol" => %{"author_logins" => ["alice", "bob"]}}}
      assert Workspace.pr_patrol_author_scope(ws) == {:logins, ["alice", "bob"]}

      ws = %Workspace{config: %{"pr_patrol" => %{"author_logins" => "alice"}}}
      assert Workspace.pr_patrol_author_scope(ws) == {:logins, ["alice"]}
    end
  end

  describe "push_decision/3" do
    test "refuses a foreign-authored PR when author_logins is unset, with a reason" do
      ws = workspace!(%{})
      stub_pr_author(7, "nbriar")

      assert {:refused, reason} = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
      assert reason =~ "nbriar"
      assert reason =~ "author_logins"
    end

    test "allows a PR authored by the fleet login" do
      ws = workspace!(%{"our_login" => "fleet-bot"})
      stub_pr_author(7, "fleet-bot")

      assert :ok = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
    end

    test "allows a PR linked to a Wardmast ticket" do
      ws = workspace!(%{})
      stub_pr_author(7, "the-operator")

      {:ok, own} =
        Ash.create(Issue, %{title: "own", workspace_id: ws.id, issue_type: :feature})

      {:ok, _} = Ash.update(own, %{pr_ref: "owner/repo#7"}, action: :update)

      assert :ok = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
    end

    test "with a login list: an author on the list is allowed, another is refused" do
      ws = workspace!(%{"author_logins" => ["ryanborn"]})

      stub_pr_author(7, "ryanborn")
      assert :ok = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")

      stub_pr_author(8, "nbriar")
      assert {:refused, _} = AuthorScope.push_decision(follow_up!(ws, "8"), ws, "owner/repo")
    end

    test "author_logins \"*\" allows any author, without asking the forge" do
      ws = workspace!(%{"author_logins" => "*"})
      Req.Test.stub(@stub, fn _conn -> raise "the forge must not be asked under \"*\"" end)

      assert :ok = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
    end

    test "fails closed when the author cannot be resolved" do
      ws = workspace!(%{})
      stub_pr_author(7, nil)

      assert {:refused, reason} = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
      assert reason =~ "could not be resolved"
    end

    test "fails closed when the forge call errors" do
      ws = workspace!(%{})

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:refused, _} = AuthorScope.push_decision(follow_up!(ws, "7"), ws, "owner/repo")
    end

    test "a task that is not a follow-up on an existing PR is not this guard's business" do
      ws = workspace!(%{})
      {:ok, plain} = Ash.create(Issue, %{title: "plain", workspace_id: ws.id})

      assert :ok = AuthorScope.push_decision(plain, ws, "owner/repo")
    end
  end

  describe "Dispatch.apply_push_guard/3" do
    defp refused_events(ws) do
      Record
      |> Ash.Query.filter(workspace_id == ^ws.id and topic == "follow_up_push_refused")
      |> Ash.read!()
    end

    test "a foreign-authored PR: the dispatch carries the refusal and records it" do
      ws = workspace!(%{})
      stub_pr_author(7, "nbriar")
      task = follow_up!(ws, "7")

      opts = Dispatch.apply_push_guard(task, [repo: "owner/repo"], ws)

      assert reason = Keyword.fetch!(opts, :push_refused)
      assert reason =~ "nbriar"

      assert [event] = refused_events(ws)
      assert event.payload["task_id"] == task.id
      assert event.payload["reason"] == reason
      assert event.payload["source_pr"] == "7"
    end

    test "an in-scope PR: dispatch is untouched and nothing is recorded" do
      ws = workspace!(%{"author_logins" => ["ryanborn"]})
      stub_pr_author(7, "ryanborn")

      opts = Dispatch.apply_push_guard(follow_up!(ws, "7"), [repo: "owner/repo"], ws)

      refute Keyword.has_key?(opts, :push_refused)
      assert refused_events(ws) == []
    end
  end

  describe "the refused worker's briefing" do
    test "tells the worker it may comment but must not push, and drops the push instructions" do
      ws = workspace!(%{})
      task = follow_up!(ws, "7")

      prompt = Dispatch.prompt_for_task(task, push_refused: "PR 7 is authored by nbriar")

      assert prompt =~ "PUSH REFUSED"
      assert prompt =~ "PR 7 is authored by nbriar"
      assert prompt =~ "do NOT push"
      refute prompt =~ "+ push (`git push`)"
    end

    test "without a refusal the follow-up briefing is unchanged" do
      ws = workspace!(%{})
      prompt = Dispatch.prompt_for_task(follow_up!(ws, "7"), [])

      refute prompt =~ "PUSH REFUSED"
      assert prompt =~ "git push"
    end
  end
end
