defmodule ArbiterWeb.Api.TrackerControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.GitHub.Config

  @viewer "tracker-worker"
  @env_var "ARBITER_TRACKER_CTRL_TOKEN"

  setup %{conn: conn} do
    System.put_env(@env_var, "tracker-test-token")

    {:ok, github_ws} =
      Ash.create(Workspace, %{
        name: "tracker-ctrl-gh",
        prefix: "tctl",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    {:ok, none_ws} = Ash.create(Workspace, %{name: "tracker-ctrl-none", prefix: "tcno"})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), gh: github_ws, none: none_ws}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fun)

  describe "GET /api/workspaces/:workspace_id/tracker/issues" do
    test "returns normalized issue summaries for a GitHub-configured workspace", %{
      conn: conn,
      gh: ws
    } do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [
              %{
                "number" => 42,
                "title" => "First",
                "state" => "open",
                "html_url" => "https://github.com/ryanrborn/arbiter/issues/42",
                "assignees" => [%{"login" => @viewer}]
              }
            ])
        end
      end)

      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      body = json_response(conn, 200)
      assert body["supported"] == true
      assert [item] = body["data"]
      assert item["ref"] == "42"
      assert item["title"] == "First"
      assert item["status"] == "open"
      assert item["url"] == "https://github.com/ryanrborn/arbiter/issues/42"
      assert item["assignees"] == [@viewer]
    end

    # bd-43sydg: a GitHub App cannot be an assignee, so with no personal token the
    # listing is by claim label and the response says so.
    test "a GitHub App tracker with no personal token lists by label and says so", %{conn: conn} do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      mint = Arbiter.Worker.GitCredential.HTTP
      Application.put_env(:arbiter, :host_credential_req_options, plug: {Req.Test, mint})
      Arbiter.Worker.HostCredential.Cache.clear()
      on_exit(fn -> Application.delete_env(:arbiter, :host_credential_req_options) end)

      Req.Test.stub(mint, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"token" => "ghs_app", "expires_at" => "2099-01-01T00:00:00Z"})
      end)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "tracker-ctrl-app",
          prefix: "tcap",
          config: %{
            "tracker" => %{
              "type" => "github",
              "config" => %{"owner" => "acme", "repo" => "tonic", "claim_label" => "mine"}
            },
            "git_credentials" => %{
              "repos" => %{
                "tonic" => %{
                  "kind" => "github_app",
                  "app_id" => "42",
                  "installation_id" => "7",
                  "private_key_secret" => "APP_KEY"
                }
              }
            }
          },
          secrets: %{"APP_KEY" => pem}
        })

      stub(fn conn ->
        assert ["Bearer ghs_app"] = Plug.Conn.get_req_header(conn, "authorization")
        assert conn.request_path == "/repos/acme/tonic/issues"
        assert URI.decode_query(conn.query_string)["labels"] == "mine"
        Req.Test.json(conn, [%{"number" => 9, "title" => "Labelled", "state" => "open"}])
      end)

      body = conn |> get(~p"/api/workspaces/#{ws.id}/tracker/issues") |> json_response(200)
      assert [%{"ref" => "9"}] = body["data"]
      assert %{"mode" => "label", "label" => "mine", "note" => note} = body["filter"]
      assert note =~ "mine"
    end

    test "returns supported=false with empty data when tracker is none", %{conn: conn, none: ws} do
      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      body = json_response(conn, 200)
      assert body["supported"] == false
      assert body["data"] == []
    end

    test "401 from tracker is surfaced as a tracker_error envelope", %{conn: conn, gh: ws} do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"message" => "Bad credentials"})
        end
      end)

      conn = get(conn, ~p"/api/workspaces/#{ws.id}/tracker/issues")
      assert %{"error" => %{"type" => "tracker_error"}} = json_response(conn, 401)
    end
  end

  describe "POST /api/workspaces/:workspace_id/tracker/tickets" do
    # bd-1ozks5: `assignee` is still accepted for one release — the local
    # assignee field is gone, so it's ignored and reported back as a warning
    # rather than rejected outright.
    test "accepts and ignores a deprecated `assignee`, with a warning", %{conn: conn, gh: ws} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 501, "html_url" => "https://github.com/o/r/issues/501"})
      end)

      conn =
        post(conn, ~p"/api/workspaces/#{ws.id}/tracker/tickets", %{
          "title" => "unclaimed work",
          "assignee" => "alice"
        })

      body = json_response(conn, 201)
      assert body["ref"] == "501"
      assert [warning] = body["warnings"]
      assert warning =~ "assignee"
    end

    test "no warnings key when assignee isn't passed", %{conn: conn, gh: ws} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 502, "html_url" => "https://github.com/o/r/issues/502"})
      end)

      conn = post(conn, ~p"/api/workspaces/#{ws.id}/tracker/tickets", %{"title" => "clean"})

      body = json_response(conn, 201)
      refute Map.has_key?(body, "warnings")
    end
  end
end
