defmodule WardmastWeb.WorkspaceTrackerCredentialsTest do
  @moduledoc """
  Credential entry for a workspace's tracker, driven through the real page
  (bd-9ssqnd): the secret vault (create / replace / delete, write-only), the
  connection test, and the GitHub/GitLab OAuth device flow. Every network call
  lands on a `Req.Test` stub — nothing here reaches a real tracker or provider.
  """
  use WardmastWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Wardmast.Tasks.Workspace

  @value "sup3r-s3cret-value-1234"
  @token "gho_device_flow_token_9876"
  @device_stub Wardmast.Trackers.DeviceFlow.HTTP
  @github_stub Wardmast.Trackers.GitHub.HTTP

  defp new_workspace(type, config \\ %{}, secrets \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "tc-#{System.unique_integer([:positive])}",
        prefix: "tc",
        secrets: secrets,
        config: %{"tracker" => %{"type" => type, "config" => config}}
      })

    ws
  end

  defp stored(ws), do: ws.id |> then(&Ash.get!(Workspace, &1)) |> Workspace.secrets_map()

  defp json(conn, status \\ 200, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  describe "secret vault" do
    test "create stores the value, shows only the key and never echoes the value", %{conn: conn} do
      ws = new_workspace("github")
      {:ok, view, _} = live_workspace(conn, ws.id)

      view |> element("button[phx-click=open_secret_modal]") |> render_click()

      log =
        capture_log([level: :debug], fn ->
          html =
            view
            |> form("#secret-form", %{"secret" => %{"key" => "gh_pat", "value" => @value}})
            |> render_submit()

          send(self(), {:html, html})
        end)

      assert_received {:html, html}
      assert stored(ws) == %{"gh_pat" => @value}

      assert has_element?(view, "#secret-keys", "gh_pat")
      refute html =~ @value
      refute render(view) =~ @value
      refute log =~ @value
    end

    test "the value input is never pre-filled, even when replacing", %{conn: conn} do
      ws = new_workspace("github", %{}, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)

      html = view |> element("#replace-secret-gh_pat") |> render_click()

      refute html =~ @value
      assert has_element?(view, "#secret-form input[name='secret[key]'][readonly]")
      assert has_element?(view, "#secret-form input[type=password][name='secret[value]']")
      assert has_element?(view, "#secret-form input[name='secret[value]'][value='']")
    end

    test "replace overwrites the stored value", %{conn: conn} do
      ws = new_workspace("github", %{}, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)

      view |> element("#replace-secret-gh_pat") |> render_click()

      view
      |> form("#secret-form", %{"secret" => %{"key" => "gh_pat", "value" => "rotated-value"}})
      |> render_submit()

      assert stored(ws) == %{"gh_pat" => "rotated-value"}
      refute render(view) =~ "rotated-value"
    end

    test "delete removes the secret", %{conn: conn} do
      ws = new_workspace("github", %{}, %{"gh_pat" => @value, "keep" => "x"})
      {:ok, view, _} = live_workspace(conn, ws.id)

      view
      |> element("#secret-keys button[phx-click=rm_secret][phx-value-key=gh_pat]")
      |> render_click()

      assert Map.keys(stored(ws)) == ["keep"]
      refute has_element?(view, "#secret-keys", "gh_pat")
    end

    test "REST responses carry the key names but never the value", %{conn: conn} do
      ws = new_workspace("github", %{}, %{"gh_pat" => @value})

      body =
        coordinator_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/workspaces/#{ws.id}")
        |> json_response(200)

      assert body["secret_keys"] == ["gh_pat"]
      refute Jason.encode!(body) =~ @value
      _ = conn
    end
  end

  describe "credentials_ref + connection test" do
    @gh %{"owner" => "acme", "repo" => "widgets"}

    test "saving points credentials_ref at a stored secret", %{conn: conn} do
      ws = new_workspace("github", @gh, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)

      view
      |> form("#tracker-config-form", %{
        "tracker_config" => %{"credentials_ref" => "secret:gh_pat"}
      })
      |> render_submit()

      saved = Ash.get!(Workspace, ws.id)
      assert get_in(saved.config, ["tracker", "config", "credentials_ref"]) == "secret:gh_pat"
    end

    test "a passing test reports the authenticated identity", %{conn: conn} do
      ws = new_workspace("github", @gh, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)

      Req.Test.stub(@github_stub, fn conn ->
        assert ["Bearer " <> @value] = Plug.Conn.get_req_header(conn, "authorization")
        json(conn, %{"login" => "octocat"})
      end)

      view
      |> form("#tracker-config-form", %{
        "tracker_config" => %{"credentials_ref" => "secret:gh_pat"}
      })
      |> render_submit(%{"tracker_config" => %{"action" => "test"}})

      html = render_async(view)

      assert has_element?(view, "#tracker-connection-result[data-status=ok]", "octocat")
      refute html =~ @value
    end

    test "a failing test reports the tracker's error and no secret", %{conn: conn} do
      ws = new_workspace("github", @gh, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)

      Req.Test.stub(@github_stub, fn conn ->
        json(conn, 401, %{"message" => "Bad credentials for #{@value}"})
      end)

      view
      |> form("#tracker-config-form", %{
        "tracker_config" => %{"credentials_ref" => "secret:gh_pat"}
      })
      |> render_submit(%{"tracker_config" => %{"action" => "test"}})

      html = render_async(view)

      assert has_element?(
               view,
               "#tracker-connection-result[data-status=error]",
               "Bad credentials"
             )

      refute html =~ @value
    end

    test "testing does not save the form", %{conn: conn} do
      ws = new_workspace("github", @gh, %{"gh_pat" => @value})
      {:ok, view, _} = live_workspace(conn, ws.id)
      Req.Test.stub(@github_stub, fn conn -> json(conn, %{"login" => "octocat"}) end)

      view
      |> form("#tracker-config-form", %{
        "tracker_config" => %{"credentials_ref" => "secret:gh_pat"}
      })
      |> render_submit(%{"tracker_config" => %{"action" => "test"}})

      _ = render_async(view)

      saved = Ash.get!(Workspace, ws.id)
      refute get_in(saved.config, ["tracker", "config", "credentials_ref"])
    end
  end

  describe "device flow" do
    setup do
      test = self()
      Application.put_env(:wardmast, :device_flow_sleep, fn ms -> send(test, {:slept, ms}) end)
      on_exit(fn -> Application.delete_env(:wardmast, :device_flow_sleep) end)
      :ok
    end

    defp device_code_response(extra \\ %{}) do
      Map.merge(
        %{
          "device_code" => "dev-code-123",
          "user_code" => "WDJB-MJHT",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        },
        extra
      )
    end

    # Serves the device-code request once, then each token poll from `polls`
    # in turn (the last repeats).
    defp stub_device(polls, device \\ device_code_response()) do
      {:ok, agent} = Agent.start_link(fn -> polls end)

      Req.Test.stub(@device_stub, fn conn ->
        if String.ends_with?(conn.request_path, "/device/code") or
             String.ends_with?(conn.request_path, "/authorize_device") do
          json(conn, device)
        else
          resp = Agent.get_and_update(agent, fn [h | t] -> {h, if(t == [], do: [h], else: t)} end)
          json(conn, resp)
        end
      end)
    end

    defp start_flow(view, client_id \\ "Iv1.testclient") do
      view
      |> form("#device-flow-form", %{"device" => %{"client_id" => client_id}})
      |> render_submit()
    end

    test "shows the code and URL while polling, then stores the token as a secret", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"error" => "authorization_pending"}, %{"access_token" => @token}])

      # Block the poll task's first sleep so the waiting state is observable.
      test = self()

      Application.put_env(:wardmast, :device_flow_sleep, fn ms ->
        send(test, {:sleeping, self(), ms})
        receive do: (:go -> :ok)
      end)

      start_flow(view)
      assert_receive {:sleeping, task, 5000}, 2_000

      assert has_element?(view, "#device-flow-code", "WDJB-MJHT")
      assert has_element?(view, "#device-flow-url[href='https://github.com/login/device']")
      assert has_element?(view, "#device-flow-status[data-status=waiting]")
      refute has_element?(view, "#device-flow-form")

      send(task, :go)
      html = render_async(view)

      assert stored(ws) == %{"github_oauth_token" => @token}
      assert has_element?(view, "#secret-keys", "github_oauth_token")
      assert has_element?(view, "#device-flow-status[data-status=done]")
      refute html =~ @token
      refute render(view) =~ @token

      saved = Ash.get!(Workspace, ws.id)

      assert get_in(saved.config, ["tracker", "config", "credentials_ref"]) ==
               "secret:github_oauth_token"
    end

    test "an existing credentials_ref is left alone", %{conn: conn} do
      ws = new_workspace("github", Map.put(@gh, "credentials_ref", "env:GITHUB_TOKEN"))
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"access_token" => @token}])

      start_flow(view)
      render_async_settled(view)

      assert stored(ws) == %{"github_oauth_token" => @token}
      saved = Ash.get!(Workspace, ws.id)

      assert get_in(saved.config, ["tracker", "config", "credentials_ref"]) ==
               "env:GITHUB_TOKEN"
    end

    test "slow_down lengthens the polling interval", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"error" => "slow_down"}, %{"access_token" => @token}])

      start_flow(view)
      render_async_settled(view)

      assert_received {:slept, 10_000}
      assert stored(ws) == %{"github_oauth_token" => @token}
    end

    test "denied is reported and nothing is stored", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"error" => "access_denied"}])

      start_flow(view)
      render_async_settled(view)

      assert has_element?(view, "#device-flow-status[data-status=error]", "denied")
      assert has_element?(view, "#device-flow-form")
      assert stored(ws) == %{}
    end

    test "expired is reported and nothing is stored", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)

      stub_device(
        [%{"error" => "authorization_pending"}],
        device_code_response(%{"expires_in" => 10})
      )

      start_flow(view)
      render_async_settled(view)

      assert has_element?(view, "#device-flow-status[data-status=error]", "expired")
      assert stored(ws) == %{}
    end

    test "a provider that rejects the client id is reported before any code is shown", %{
      conn: conn
    } do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)

      Req.Test.stub(@device_stub, fn conn ->
        json(conn, %{"error" => "incorrect_client_credentials", "error_description" => "bad id"})
      end)

      start_flow(view)
      render_async_settled(view)

      assert has_element?(view, "#device-flow-status[data-status=error]", "bad id")
      refute has_element?(view, "#device-flow-code")
    end

    test "gitlab runs the same flow against the configured host", %{conn: conn} do
      ws = new_workspace("gitlab", %{"host" => "gitlab.example.com", "project_id" => "7"})
      {:ok, view, _} = live_workspace(conn, ws.id)
      test = self()

      Req.Test.stub(@device_stub, fn conn ->
        send(test, {:gitlab_req, conn.host, conn.request_path})

        if conn.request_path == "/oauth/authorize_device",
          do:
            json(
              conn,
              device_code_response(%{
                "verification_uri" => "https://gitlab.example.com/oauth/device"
              })
            ),
          else: json(conn, %{"access_token" => @token})
      end)

      start_flow(view)
      render_async_settled(view)

      assert_received {:gitlab_req, "gitlab.example.com", "/oauth/authorize_device"}
      assert_received {:gitlab_req, "gitlab.example.com", "/oauth/token"}
      assert stored(ws) == %{"gitlab_oauth_token" => @token}
    end

    test "other trackers get no device flow, only the PAT path", %{conn: conn} do
      ws = new_workspace("jira", %{"host" => "x.atlassian.net", "project_key" => "AX"})
      {:ok, view, _} = live_workspace(conn, ws.id)

      refute has_element?(view, "#device-flow-form")
      assert has_element?(view, "button[phx-click=open_secret_modal]")
    end

    test "cancel stops polling and offers a new start", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"error" => "authorization_pending"}])
      test = self()

      Application.put_env(:wardmast, :device_flow_sleep, fn ms ->
        send(test, {:sleeping, self(), ms})
        receive do: (:never -> :ok)
      end)

      start_flow(view)
      assert_receive {:sleeping, task, _}, 2_000
      ref = Process.monitor(task)

      view |> element("#device-flow-cancel") |> render_click()

      assert_receive {:DOWN, ^ref, :process, ^task, _}, 2_000
      assert has_element?(view, "#device-flow-form")
      refute has_element?(view, "#device-flow-code")
      assert stored(ws) == %{}
    end

    test "the device code and token never reach the logs", %{conn: conn} do
      ws = new_workspace("github", @gh)
      {:ok, view, _} = live_workspace(conn, ws.id)
      stub_device([%{"access_token" => @token}])

      log =
        capture_log([level: :debug], fn ->
          start_flow(view)
          render_async_settled(view)
        end)

      refute log =~ @token
      refute log =~ "dev-code-123"
    end
  end
end
