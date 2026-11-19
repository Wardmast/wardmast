defmodule Wardmast.Trackers.DeviceFlowTest do
  use ExUnit.Case, async: false

  alias Wardmast.Trackers.DeviceFlow

  @stub Wardmast.Trackers.DeviceFlow.HTTP

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  defp json(conn, status, body) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp flow(overrides \\ %{}) do
    Map.merge(
      %DeviceFlow{
        provider: :github,
        client_id: "cid",
        token_url: "https://github.com/login/oauth/access_token",
        device_code: "dev-code",
        user_code: "ABCD-1234",
        verification_uri: "https://github.com/login/device",
        expires_in: 900,
        interval: 5
      },
      overrides
    )
  end

  describe "start/2" do
    test "github: posts client_id + scope to github.com and returns the code and URL" do
      test = self()

      stub(fn conn ->
        {params, conn} = form(conn)
        send(test, {:req, conn.host, conn.request_path, params})

        json(conn, 200, %{
          "device_code" => "dev-code",
          "user_code" => "ABCD-1234",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      end)

      assert {:ok, %DeviceFlow{} = f} = DeviceFlow.start(:github, client_id: "cid")
      assert f.user_code == "ABCD-1234"
      assert f.verification_uri == "https://github.com/login/device"
      assert f.interval == 5
      assert f.expires_in == 900

      assert_received {:req, "github.com", "/login/device/code", %{"client_id" => "cid"} = p}
      assert p["scope"] =~ "repo"
    end

    test "github enterprise: derives the host from the tracker base_url" do
      test = self()

      stub(fn conn ->
        send(test, {:host, conn.host})

        json(conn, 200, %{
          "device_code" => "d",
          "user_code" => "U",
          "verification_uri" => "https://ghe.example.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      end)

      assert {:ok, _} =
               DeviceFlow.start(:github,
                 client_id: "cid",
                 tracker_config: %{"base_url" => "https://ghe.example.com/api/v3"}
               )

      assert_received {:host, "ghe.example.com"}
    end

    test "gitlab: posts to the configured host's oauth/authorize_device" do
      test = self()

      stub(fn conn ->
        send(test, {:req, conn.host, conn.request_path})

        json(conn, 200, %{
          "device_code" => "d",
          "user_code" => "WXYZ",
          "verification_uri" => "https://gitlab.example.com/oauth/device",
          "verification_uri_complete" => "https://gitlab.example.com/oauth/device?user_code=WXYZ",
          "expires_in" => 300
        })
      end)

      assert {:ok, f} =
               DeviceFlow.start(:gitlab,
                 client_id: "cid",
                 tracker_config: %{"host" => "gitlab.example.com"}
               )

      assert f.verification_uri_complete =~ "user_code=WXYZ"
      # GitLab omits `interval`; the RFC 8628 default applies.
      assert f.interval == 5
      assert_received {:req, "gitlab.example.com", "/oauth/authorize_device"}
    end

    test "a missing client id is a clear error and makes no request" do
      stub(fn _conn -> flunk("no request expected") end)
      assert {:error, msg} = DeviceFlow.start(:github, client_id: "")
      assert msg =~ "client ID"
    end

    test "the provider rejecting the client is surfaced" do
      stub(fn conn ->
        json(conn, 200, %{"error" => "incorrect_client_credentials", "error_description" => "bad"})
      end)

      assert {:error, msg} = DeviceFlow.start(:github, client_id: "nope")
      assert msg =~ "bad"
    end
  end

  describe "poll/1" do
    test "approved: returns the access token and sends the device-code grant" do
      test = self()

      stub(fn conn ->
        {params, conn} = form(conn)
        send(test, {:params, params})
        json(conn, 200, %{"access_token" => "gho_secret", "token_type" => "bearer"})
      end)

      assert {:ok, "gho_secret"} = DeviceFlow.poll(flow())

      assert_received {:params,
                       %{
                         "client_id" => "cid",
                         "device_code" => "dev-code",
                         "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
                       }}
    end

    test "authorization_pending: still waiting" do
      stub(fn conn -> json(conn, 200, %{"error" => "authorization_pending"}) end)
      assert :pending = DeviceFlow.poll(flow())
    end

    test "slow_down: returns a flow with a longer interval" do
      stub(fn conn -> json(conn, 200, %{"error" => "slow_down", "interval" => 15}) end)
      assert {:slow_down, %DeviceFlow{interval: 15}} = DeviceFlow.poll(flow())
    end

    test "slow_down without a new interval adds the RFC 8628 five seconds" do
      stub(fn conn -> json(conn, 400, %{"error" => "slow_down"}) end)
      assert {:slow_down, %DeviceFlow{interval: 10}} = DeviceFlow.poll(flow())
    end

    test "expired_token and access_denied are terminal (GitLab sends them as 400)" do
      stub(fn conn -> json(conn, 400, %{"error" => "expired_token"}) end)
      assert {:error, :expired} = DeviceFlow.poll(flow())

      stub(fn conn -> json(conn, 400, %{"error" => "access_denied"}) end)
      assert {:error, :denied} = DeviceFlow.poll(flow())
    end

    test "any other error is reported with its description" do
      stub(fn conn ->
        json(conn, 200, %{"error" => "unsupported_grant_type", "error_description" => "nope"})
      end)

      assert {:error, {:provider, msg}} = DeviceFlow.poll(flow())
      assert msg =~ "nope"
    end
  end

  describe "await/2" do
    setup do
      {:ok, sleeps: start_supervised!({Agent, fn -> [] end})}
    end

    defp sleeper(agent), do: fn ms -> Agent.update(agent, &[ms | &1]) end
    defp slept(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

    defp sequence(responses) do
      {:ok, agent} = Agent.start_link(fn -> responses end)

      stub(fn conn ->
        resp = Agent.get_and_update(agent, fn [h | t] -> {h, if(t == [], do: [h], else: t)} end)
        json(conn, 200, resp)
      end)
    end

    test "polls through pending until approved, sleeping the interval between polls", %{
      sleeps: sleeps
    } do
      sequence([
        %{"error" => "authorization_pending"},
        %{"error" => "authorization_pending"},
        %{"access_token" => "tok"}
      ])

      assert {:ok, "tok"} = DeviceFlow.await(flow(), sleep: sleeper(sleeps))
      assert slept(sleeps) == [5000, 5000]
    end

    test "slow_down lengthens every later sleep", %{sleeps: sleeps} do
      sequence([
        %{"error" => "authorization_pending"},
        %{"error" => "slow_down"},
        %{"access_token" => "tok"}
      ])

      assert {:ok, "tok"} = DeviceFlow.await(flow(), sleep: sleeper(sleeps))
      assert slept(sleeps) == [5000, 10_000]
    end

    test "denied stops at once", %{sleeps: sleeps} do
      sequence([%{"error" => "access_denied"}])
      assert {:error, :denied} = DeviceFlow.await(flow(), sleep: sleeper(sleeps))
      assert slept(sleeps) == []
    end

    test "gives up as :expired once the code's lifetime has been waited out", %{sleeps: sleeps} do
      sequence([%{"error" => "authorization_pending"}])

      assert {:error, :expired} =
               DeviceFlow.await(flow(%{expires_in: 20}), sleep: sleeper(sleeps))

      assert Enum.sum(slept(sleeps)) <= 20_000
    end

    test "the provider reporting expiry is honoured", %{sleeps: sleeps} do
      sequence([%{"error" => "authorization_pending"}, %{"error" => "expired_token"}])
      assert {:error, :expired} = DeviceFlow.await(flow(), sleep: sleeper(sleeps))
    end
  end

  describe "describe_error/2" do
    test "has a distinct, actionable message per outcome" do
      msgs =
        for e <- [:expired, :denied, {:provider, "boom"}, {:network, "down"}],
            do: DeviceFlow.describe_error(e, :github)

      assert length(Enum.uniq(msgs)) == 4
      assert Enum.any?(msgs, &(&1 =~ "boom"))
    end
  end
end
