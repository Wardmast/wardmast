defmodule Arbiter.Trackers.GitHubAppCredentialTest do
  @moduledoc """
  bd-43sydg: the GitHub tracker resolves its token like the merger does
  (bd-bsmkfu) — a repo whose `git_credentials.repos.<repo>` entry is a
  `github_app` is served with the App's repo-restricted installation token, not
  `tracker.config.credentials_ref`; a repo without one keeps `credentials_ref`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Trackers.GitHub
  alias Arbiter.Trackers.GitHub.{Config, Error}
  alias Arbiter.Worker.HostCredential

  @mint Arbiter.Worker.GitCredential.HTTP
  @http Arbiter.Trackers.GitHub.HTTP
  @env_var "BD43SYDG_PERSONAL_TOKEN"
  @app_token "ghs_installation_token"
  @personal "personal-classic-token"

  setup do
    System.put_env(@env_var, @personal)
    HostCredential.Cache.clear()
    Application.put_env(:arbiter, :host_credential_req_options, plug: {Req.Test, @mint})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
      Application.delete_env(:arbiter, :host_credential_req_options)
    end)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    %{pem: pem}
  end

  defp workspace(pem, tracker_config, git_credentials \\ nil) do
    git_credentials =
      git_credentials ||
        %{
          "repos" => %{
            "tonic" => %{
              "kind" => "github_app",
              "app_id" => "42",
              "installation_id" => "7",
              "private_key_secret" => "APP_KEY"
            },
            "legacy" => %{"legacy_operator" => true}
          }
        }

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ghapp-#{System.unique_integer([:positive])}",
        prefix: "ghapp",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => Map.merge(%{"owner" => "acme", "repo" => "tonic"}, tracker_config)
          },
          "git_credentials" => git_credentials
        },
        secrets: %{"APP_KEY" => pem}
      })

    ws
  end

  defp personal_ref, do: %{"credentials_ref" => "env:#{@env_var}"}

  defp stub_mint(status \\ 201) do
    test = self()

    Req.Test.stub(@mint, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:mint, conn.request_path, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(
        if status == 201,
          do: %{"token" => @app_token, "expires_at" => "2099-01-01T00:00:00Z"},
          else: %{"message" => "Not Found"}
      )
    end)
  end

  # Records the Authorization header of every tracker request, answers with
  # `reply.(conn)`.
  defp stub_api(reply \\ nil) do
    test = self()

    Req.Test.stub(@http, fn conn ->
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:api, conn.method, conn.request_path, auth, conn.query_string})

      if reply do
        reply.(conn)
      else
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "number" => 42,
          "state" => "open",
          "labels" => [],
          "login" => "octocat"
        })
      end
    end)
  end

  defp prepare(ws), do: GitHub.prepare(ws, repo: "tonic")

  describe "a repo with a github_app entry" do
    test "create, update_fields, transition and close carry the installation token",
         %{pem: pem} do
      stub_mint()
      stub_api()
      prepare(workspace(pem, personal_ref()))
      bearer = "Bearer " <> @app_token

      assert {:ok, "42"} = GitHub.create(%{title: "t"})
      assert_received {:api, "POST", "/repos/acme/tonic/issues", ^bearer, _}

      assert :ok = GitHub.update_fields("42", %{title: "new"})
      assert_received {:api, "PATCH", "/repos/acme/tonic/issues/42", ^bearer, _}

      assert :ok = GitHub.transition("42", :in_progress)
      assert_received {:api, "GET", "/repos/acme/tonic/issues/42", ^bearer, _}
      assert_received {:api, "PATCH", "/repos/acme/tonic/issues/42", ^bearer, _}

      assert :ok = GitHub.transition("42", :closed)
      assert_received {:api, "PATCH", "/repos/acme/tonic/issues/42", ^bearer, _}

      assert {:ok, _} = GitHub.fetch("42")
      assert_received {:api, "GET", "/repos/acme/tonic/issues/42", ^bearer, _}

      refute_received {:api, _, _, "Bearer " <> @personal, _}
    end

    test "the token is minted for the tracker repo with issues, pull_requests, metadata only",
         %{pem: pem} do
      stub_mint()
      stub_api()
      prepare(workspace(pem, personal_ref()))

      assert {:ok, _} = GitHub.fetch("42")

      assert_received {:mint, "/app/installations/7/access_tokens", body}
      assert body["repositories"] == ["tonic"]

      assert body["permissions"] == %{
               "issues" => "write",
               "pull_requests" => "write",
               "metadata" => "read"
             }
    end

    test "github_token (credentials_ref) is optional with an App", %{pem: pem} do
      stub_mint()
      stub_api()
      prepare(workspace(pem, %{}))

      assert {:ok, "42"} = GitHub.create(%{title: "t"})
      bearer = "Bearer " <> @app_token
      assert_received {:api, "POST", _, ^bearer, _}
    end

    test "a mint failure is an error, never a fallback to the personal token", %{pem: pem} do
      stub_mint(404)
      stub_api()
      prepare(workspace(pem, personal_ref()))

      assert {:error, %Error{kind: :config_missing, message: message}} =
               GitHub.create(%{title: "t"})

      assert message =~ "scoped GitHub App token"
      refute_received {:api, _, _, _, _}

      assert {:error, %Error{kind: :config_missing}} = GitHub.transition("42", :closed)
      assert {:error, %Error{kind: :config_missing}} = GitHub.update_fields("42", %{title: "x"})
      refute_received {:api, _, _, _, _}
    end

    test "resolves through Trackers.prepare/3 for the tracker repo slug when no repo is named",
         %{pem: pem} do
      stub_mint()
      stub_api()
      GitHub.prepare(workspace(pem, personal_ref()))

      assert {:ok, _} = GitHub.fetch("42")
      bearer = "Bearer " <> @app_token
      assert_received {:api, "GET", _, ^bearer, _}
    end
  end

  describe "a repo without a github_app entry" do
    test "uses credentials_ref as before", %{pem: pem} do
      stub_api()
      stub_mint()
      ws = workspace(pem, personal_ref() |> Map.put("repo", "other"))
      GitHub.prepare(ws, repo: "legacy")

      assert {:ok, "42"} = GitHub.create(%{title: "t"})
      bearer = "Bearer " <> @personal
      assert_received {:api, "POST", "/repos/acme/other/issues", ^bearer, _}
      refute_received {:mint, _, _}
    end

    test "a workspace with no git_credentials uses credentials_ref", %{pem: pem} do
      stub_api()
      ws = workspace(pem, personal_ref(), %{})
      GitHub.prepare(ws)

      assert {:ok, _} = GitHub.fetch("42")
      bearer = "Bearer " <> @personal
      assert_received {:api, "GET", _, ^bearer, _}
    end

    test "no credentials_ref and no App is a config error", %{pem: pem} do
      ws = workspace(pem, %{}, %{})
      GitHub.prepare(ws)

      assert {:error, %Error{kind: :config_missing, message: message}} = GitHub.fetch("42")
      assert message =~ "credentials_ref"
    end
  end

  describe "claim identity without a personal token" do
    test "list_open filters on the claim label, not the assignee, and says so", %{pem: pem} do
      stub_mint()

      stub_api(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"number" => 5, "title" => "x"}])
      end)

      ws = workspace(pem, %{"claim_label" => "arbiter-claim"})
      prepare(ws)

      assert {:ok, "label:arbiter-claim"} = GitHub.current_user()

      assert {:ok, [%{ref: "5"}]} = GitHub.list_open(assignee: "label:arbiter-claim")
      bearer = "Bearer " <> @app_token
      assert_received {:api, "GET", "/repos/acme/tonic/issues", ^bearer, query}
      params = URI.decode_query(query)
      assert params["labels"] == "arbiter-claim"
      refute Map.has_key?(params, "assignee")
      refute_received {:api, _, "/user", _, _}

      assert %{mode: :label, label: "arbiter-claim", note: note} = GitHub.claim_filter()
      assert note =~ "arbiter-claim"
    end

    test "Trackers.claim_filter/1 reports the label filter to the response", %{pem: pem} do
      stub_mint()
      ws = workspace(pem, %{"claim_label" => "arbiter-claim"})

      assert %{mode: :label, label: "arbiter-claim"} = Trackers.claim_filter(ws)
    end

    test "the label defaults when claim_label is unset", %{pem: pem} do
      stub_mint()
      prepare(workspace(pem, %{}))
      assert {:ok, "label:" <> label} = GitHub.current_user()
      assert label != ""
    end

    test "a labelled, unassigned issue is the claim identity's; a human-assigned one is not",
         %{pem: pem} do
      stub_mint()
      prepare(workspace(pem, %{"claim_label" => "arbiter-claim"}))

      labelled = %{"labels" => [%{"name" => "arbiter-claim"}], "assignees" => []}
      assert GitHub.assignees(labelled) == ["label:arbiter-claim"]

      taken = %{labelled | "assignees" => [%{"login" => "alice"}]}
      assert GitHub.assignees(taken) == ["alice"]

      assert GitHub.assignees(%{"labels" => [], "assignees" => []}) == []
    end

    test "with a personal token configured, assignment is still the claim identity",
         %{pem: pem} do
      stub_mint()

      stub_api(fn conn ->
        body = if conn.request_path == "/user", do: %{"login" => "octocat"}, else: []
        conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
      end)

      prepare(workspace(pem, personal_ref()))

      assert {:ok, "octocat"} = GitHub.current_user()
      personal = "Bearer " <> @personal
      assert_received {:api, "GET", "/user", ^personal, _}

      assert {:ok, []} = GitHub.list_open(assignee: "octocat")
      app = "Bearer " <> @app_token
      assert_received {:api, "GET", "/repos/acme/tonic/issues", ^app, query}
      assert URI.decode_query(query)["assignee"] == "octocat"
      assert GitHub.claim_filter() == nil
    end

    test "a plain credentials_ref workspace keeps assignment semantics", %{pem: pem} do
      ws = workspace(pem, personal_ref(), %{})
      GitHub.prepare(ws)
      assert GitHub.claim_filter() == nil
    end
  end

  describe "the responses say the claim filter is a label" do
    setup %{pem: pem} do
      stub_mint()

      stub_api(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      ws = workspace(pem, %{"claim_label" => "arbiter-claim"})
      scope = %Arbiter.MCP.Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: false}
      %{ws: ws, scope: scope}
    end

    test "tracker_list_issues carries a filter entry and lists by label", %{scope: scope} do
      assert {:ok, %{supported: true, data: [], filter: filter}} =
               Arbiter.MCP.Catalog.call(scope, "tracker_list_issues", %{})

      assert %{mode: :label, label: "arbiter-claim", note: note} = filter
      assert note =~ "label"
      assert_received {:api, "GET", "/repos/acme/tonic/issues", _, query}
      assert URI.decode_query(query)["labels"] == "arbiter-claim"
      refute_received {:api, _, "/user", _, _}
    end

    test "tracker_sync carries the same filter entry", %{scope: scope} do
      assert {:ok, %{applied: false, filter: %{mode: :label, label: "arbiter-claim"}}} =
               Arbiter.MCP.Catalog.call(scope, "tracker_sync", %{"dry" => true})
    end
  end

  describe "limiter pool accounting" do
    setup do
      name = :"limiter_app_#{System.unique_integer([:positive])}"
      start_supervised!({Limiter, name: name, probe: false})
      previous = Application.get_env(:arbiter, :github_limiter_server)
      Application.put_env(:arbiter, :github_limiter_server, name)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :github_limiter_server, previous),
          else: Application.delete_env(:arbiter, :github_limiter_server)
      end)

      %{limiter: name}
    end

    test "calls made with the App token count against the installation's pool",
         %{pem: pem, limiter: srv} do
      stub_mint()
      stub_api()
      prepare(workspace(pem, personal_ref()))

      assert {:ok, _} = GitHub.fetch("42")
      assert {:ok, _} = GitHub.fetch("42")

      stats = Limiter.stats(srv)
      assert stats[{:installation, "7"}].counts.foreground == 2
      refute Map.has_key?(stats, :shared)
      assert Limiter.pool_for(@app_token, srv) == {:installation, "7"}
    end

    test "calls made with credentials_ref are not put in the installation pool",
         %{pem: pem, limiter: srv} do
      stub_api()
      GitHub.prepare(workspace(pem, personal_ref(), %{}))

      assert {:ok, _} = GitHub.fetch("42")

      stats = Limiter.stats(srv)
      refute Map.has_key?(stats, {:installation, "7"})
      assert stats[:shared].counts.foreground == 1
    end
  end
end
