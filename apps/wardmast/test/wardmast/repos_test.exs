defmodule Wardmast.ReposTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Repos
  alias Wardmast.Tasks.Workspace

  describe "list/1" do
    test "returns empty list when no repos are configured" do
      assert Repos.list() == []
    end

    test "two-workspace same-name fixture returns both entries" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"shared-repo" => "/tmp/repo-one"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"shared-repo" => "/tmp/repo-two"}}
        })

      repos = Repos.list()

      shared_entries = Enum.filter(repos, &(&1.name == "shared-repo"))
      assert length(shared_entries) == 2

      sources = Enum.map(shared_entries, & &1.source) |> Enum.sort()
      assert sources == ["ws-one", "ws-two"]

      paths = Enum.map(shared_entries, & &1.path) |> Enum.sort()
      assert paths == ["/tmp/repo-one", "/tmp/repo-two"]

      ws_ids = Enum.map(shared_entries, & &1.workspace_id) |> Enum.sort()
      assert ws_ids == Enum.sort([ws1.id, ws2.id])
    end

    test "filters by workspace_id when provided" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"repo-a" => "/tmp/repo-a"}}
        })

      {:ok, _ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"repo-b" => "/tmp/repo-b"}}
        })

      repos1 = Repos.list(workspace_id: ws1.id)
      assert length(repos1) == 1
      assert hd(repos1).name == "repo-a"
      assert hd(repos1).source == "ws-one"
    end

    test "includes app-env fallback unless configured in workspace" do
      old_env = Application.get_env(:wardmast, :repo_paths, %{})

      try do
        Application.put_env(:wardmast, :repo_paths, %{
          "app-only" => "/tmp/app-only",
          "overridden" => "/tmp/app-overridden"
        })

        {:ok, _ws} =
          Ash.create(Workspace, %{
            name: "ws-main",
            prefix: "wm",
            config: %{"repo_paths" => %{"overridden" => "/tmp/ws-overridden"}}
          })

        repos = Repos.list()

        app_only = Enum.find(repos, &(&1.name == "app-only"))
        assert app_only
        assert app_only.path == "/tmp/app-only"
        assert app_only.source == "(app)"

        overridden_entries = Enum.filter(repos, &(&1.name == "overridden"))
        assert length(overridden_entries) == 1
        assert hd(overridden_entries).source == "ws-main"
        assert hd(overridden_entries).path == "/tmp/ws-overridden"
      after
        Application.put_env(:wardmast, :repo_paths, old_env)
      end
    end
  end

  # bd-2rdfsh: each repo reports how far its primary checkout's local target
  # branch trails origin, and whether the post-merge sync is opted in, so
  # `ward server doctor` can warn before a stale local branch misleads a gate.
  describe "primary checkout staleness (bd-2rdfsh)" do
    alias Wardmast.Test.GitFixture

    setup do
      git = GitFixture.forge_and_checkout()

      for n <- 1..3,
          do: GitFixture.commit!(git.seed, %{"u#{n}.txt" => "#{n}\n"}, "upstream #{n}")

      GitFixture.git!(git.seed, ["push", "-q", "origin", "main"])
      GitFixture.git!(git.checkout, ["fetch", "-q", "origin"])
      {:ok, git: git}
    end

    test "reports how far local main trails origin/main", %{git: git} do
      {:ok, _} =
        Ash.create(Workspace, %{
          name: "ws-stale",
          prefix: "ws",
          config: %{
            "repo_paths" => %{"widget" => %{"path" => git.checkout, "target_branch" => "main"}}
          }
        })

      assert [%{name: "widget"} = repo] = Repos.list()
      assert repo.primary_target == "main"
      assert repo.primary_behind == 3
      assert repo.primary_sync_blocker == nil
      assert repo.auto_sync_primary == false
    end

    test "carries the auto_sync_primary opt-in and a blocker when the tree is dirty", %{git: git} do
      File.write!(Path.join(git.checkout, "wip.txt"), "wip\n")

      {:ok, _} =
        Ash.create(Workspace, %{
          name: "ws-dirty",
          prefix: "wd",
          config: %{
            "merge" => %{"auto_sync_primary" => true},
            "repo_paths" => %{"widget" => git.checkout}
          }
        })

      assert [repo] = Repos.list()
      assert repo.auto_sync_primary == true
      assert repo.primary_behind == 3
      assert repo.primary_sync_blocker == :uncommitted_changes
    end

    test "is nil (unknown) when the path is not a git checkout" do
      {:ok, _} =
        Ash.create(Workspace, %{
          name: "ws-nogit",
          prefix: "wn",
          config: %{"repo_paths" => %{"ghost" => "/nonexistent/ghost"}}
        })

      assert [%{primary_behind: nil, primary_sync_blocker: nil}] = Repos.list()
    end
  end

  describe "get/2" do
    test "finds repo by name" do
      {:ok, _ws} =
        Ash.create(Workspace, %{
          name: "ws-main",
          prefix: "wm",
          config: %{"repo_paths" => %{"target-repo" => "/tmp/target-repo"}}
        })

      assert {:ok, repo} = Repos.get("target-repo")
      assert repo.name == "target-repo"
      assert repo.path == "/tmp/target-repo"
      assert repo.source == "ws-main"
    end

    test "returns not-found error for nonexistent repo" do
      assert {:error, {:not_found, msg}} = Repos.get("nonexistent")
      assert msg =~ "nonexistent"
    end

    test "scopes to workspace_id when provided" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"same-name" => "/tmp/ws1-path"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"same-name" => "/tmp/ws2-path"}}
        })

      assert {:ok, repo1} = Repos.get("same-name", workspace_id: ws1.id)
      assert repo1.path == "/tmp/ws1-path"
      assert repo1.source == "ws-one"

      assert {:ok, repo2} = Repos.get("same-name", workspace_id: ws2.id)
      assert repo2.path == "/tmp/ws2-path"
      assert repo2.source == "ws-two"
    end

    test "returns ambiguous error when same-named repo exists in multiple workspaces without scope" do
      {:ok, _ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"twin-repo" => "/tmp/twin-1"}}
        })

      {:ok, _ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"twin-repo" => "/tmp/twin-2"}}
        })

      assert {:error, {:invalid_request, msg, details}} = Repos.get("twin-repo")
      assert msg =~ "ambiguous"
      assert msg =~ "twin-repo"
      assert is_list(details.workspaces)
      assert length(details.workspaces) == 2
    end
  end

  describe "get_all/2" do
    test "two-workspace same-name fixture returns both entries" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"twin-repo" => "/tmp/twin-1"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"twin-repo" => "/tmp/twin-2"}}
        })

      entries = Repos.get_all("twin-repo")
      assert length(entries) == 2
      assert Enum.map(entries, & &1.workspace_id) |> Enum.sort() == Enum.sort([ws1.id, ws2.id])
    end
  end

  describe "open tickets on an unconfigured repo (bd-7u1b6n)" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ws-uc",
          prefix: "uc",
          config: %{"repo_paths" => %{"tonic" => "/tmp/tonic"}}
        })

      {:ok, issue} = Ash.create(Wardmast.Tasks.Issue, %{title: "t", workspace_id: ws.id})
      %{ws: ws, issue: issue}
    end

    defp set_repo!(issue, repo),
      do: issue |> Ecto.Changeset.change(repo: repo) |> Wardmast.Repo.update!()

    test "is listed as (unconfigured)", %{issue: issue} do
      set_repo!(issue, "emricare/tonic")

      assert [%{name: "emricare/tonic", path: nil}] =
               Enum.filter(Repos.list(), &(&1.source == "(unconfigured)"))
    end

    test "a configured key, or a closed ticket, is not listed", %{issue: issue} do
      assert Enum.filter(Repos.list(), &(&1.source == "(unconfigured)")) == []

      issue |> set_repo!("emricare/tonic") |> Ash.update!(%{}, action: :close)
      assert Enum.filter(Repos.list(), &(&1.source == "(unconfigured)")) == []
    end
  end
end
