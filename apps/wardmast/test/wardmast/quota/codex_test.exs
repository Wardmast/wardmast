defmodule Wardmast.Quota.CodexTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Quota.Codex
  alias Wardmast.Tasks.Workspace

  @stub_name Wardmast.Quota.Codex.HTTP

  # A representative 200 body, mirroring the shape 9router's `getCodexUsage`
  # parses: a `rate_limit` object with `primary_window` (session) and
  # `secondary_window` (weekly), each with a used-percent and a reset time.
  @usage_body %{
    "plan_type" => "plus",
    "rate_limit" => %{
      "primary_window" => %{"used_percent" => 42.5, "reset_at" => 1_782_247_200},
      "secondary_window" => %{"used_percent" => 8.0, "reset_at" => 1_782_748_800}
    }
  }

  defp workspace!(name \\ "default"), do: Ash.create!(Workspace, %{name: name})

  defp creds, do: %{access_token: "tok-abc", account_id: "acct-123"}

  describe "normalize/1" do
    test "extracts session + weekly windows from rate_limit.primary/secondary" do
      assert {:ok, attrs} = Codex.normalize(@usage_body)

      assert attrs.plan == "plus"
      assert attrs.session_used_percent == 42.5
      assert attrs.weekly_used_percent == 8.0
      assert DateTime.to_unix(attrs.session_reset_at) == 1_782_247_200
      assert DateTime.to_unix(attrs.weekly_reset_at) == 1_782_748_800
    end

    test "accepts the rate_limits alias and percent_used/resets_at keys" do
      body = %{
        "rate_limits" => %{
          "primary_window" => %{"percent_used" => 10.0, "resets_at" => 1_782_247_200}
        }
      }

      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.session_used_percent == 10.0
      # absent window → key omitted, so the upsert leaves the column nil
      refute Map.has_key?(attrs, :weekly_used_percent)
      assert DateTime.to_unix(attrs.session_reset_at) == 1_782_247_200
    end

    test "accepts rate_limits_by_limit_id.codex" do
      body = %{
        "rate_limits_by_limit_id" => %{
          "codex" => %{
            "secondary_window" => %{"used_percent" => 55.0, "resetAt" => "2026-06-24T00:00:00Z"}
          }
        }
      }

      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.weekly_used_percent == 55.0
      assert %DateTime{} = attrs.weekly_reset_at
    end

    test "clamps used-percent into 0..100" do
      body = %{"rate_limit" => %{"primary_window" => %{"used_percent" => 250.0}}}
      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.session_used_percent == 100.0
    end

    test "persists limit_window_seconds per window as window minutes" do
      body = %{
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 1.0, "limit_window_seconds" => 18_000},
          "secondary_window" => %{"used_percent" => 2.0, "window_minutes" => 10_080}
        }
      }

      assert {:ok, attrs} = Codex.normalize(body)
      assert attrs.session_window_minutes == 300
      assert attrs.weekly_window_minutes == 10_080
    end

    test "view/1 labels windows from stored length so the bar can pace" do
      row = %Wardmast.Quota.CodexQuota{
        provider: "codex",
        session_used_percent: 40.0,
        session_window_minutes: 43_200,
        session_reset_at: DateTime.utc_now()
      }

      view = Codex.view(row)
      assert view.primary_label == "30d"
      assert Wardmast.Quota.Gate.window_seconds("30d", nil) == 2_592_000
      assert Codex.view(%{row | session_window_minutes: nil}).primary_label == "session"
    end

    test "omits window minutes when the endpoint reports no length" do
      assert {:ok, attrs} = Codex.normalize(@usage_body)
      refute Map.has_key?(attrs, :session_window_minutes)
    end

    test "is a no-op when no window data is present" do
      assert Codex.normalize(%{"plan_type" => "plus"}) == :noop
      assert Codex.normalize(%{}) == :noop
    end
  end

  describe "fetch/2 — credentials absent" do
    test "no-op with a message, and makes no HTTP call" do
      ws = workspace!()

      result = Codex.fetch(ws.id, auth_path: "/nonexistent/codex/auth.json")

      assert result.codex == nil
      assert result.message =~ "not authenticated"
      assert Codex.latest(quota_account_id!(ws.id, "codex")) == nil
    end
  end

  describe "fetch/2 — happy path" do
    setup do
      prev_http_stub = Application.get_env(:wardmast, :codex_quota_http_stub)
      Application.put_env(:wardmast, :codex_quota_http_stub, true)
      on_exit(fn -> restore_env(:codex_quota_http_stub, prev_http_stub) end)
      :ok
    end

    test "upserts a snapshot and returns the normalized windows" do
      ws = workspace!()

      Req.Test.stub(@stub_name, fn conn ->
        assert ["Bearer tok-abc"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["acct-123"] = Plug.Conn.get_req_header(conn, "chatgpt-account-id")
        Req.Test.json(conn, @usage_body)
      end)

      result = Codex.fetch(ws.id, credentials: creds())

      assert result.message == nil
      assert result.auth_expired == false
      assert result.codex.plan == "plus"
      assert result.codex.session.used == 42.5
      assert result.codex.session.remaining == 57.5
      assert result.codex.session.total == 100
      assert result.codex.weekly.used == 8.0
      assert is_binary(result.codex.session.reset_at)

      # persisted, readable back
      row = Codex.latest(quota_account_id!(ws.id, "codex"))
      assert row.session_used_percent == 42.5
      assert row.weekly_used_percent == 8.0
    end

    test "broadcasts the uniform {:quota_updated, ws, view} so LiveView picks it up (bd-ajh7bd)" do
      ws = workspace!()
      Phoenix.PubSub.subscribe(Wardmast.PubSub, "quota:#{ws.id}")

      Req.Test.stub(@stub_name, fn conn -> Req.Test.json(conn, @usage_body) end)

      Codex.fetch(ws.id, credentials: creds())

      # Same message shape the Anthropic/Google paths emit — a uniform view map,
      # provider "codex", session→5h fraction — not the legacy
      # {:codex_quota_updated, ws, %CodexQuota{}} struct the LiveView ignored.
      assert_receive {:quota_updated, ws_id, view}, 2_000
      assert ws_id == ws.id
      assert is_map(view) and not is_struct(view)
      assert view.provider == "codex"
      assert_in_delta view.utilization_5h, 0.425, 0.0001
    end
  end

  describe "fetch/2 — degrade path" do
    setup do
      prev_http_stub = Application.get_env(:wardmast, :codex_quota_http_stub)
      Application.put_env(:wardmast, :codex_quota_http_stub, true)
      on_exit(fn -> restore_env(:codex_quota_http_stub, prev_http_stub) end)
      :ok
    end

    test "401 (expired token) skips the cycle gracefully without writing a snapshot" do
      ws = workspace!()

      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => "token_expired"}})
      end)

      result = Codex.fetch(ws.id, credentials: creds())

      assert result.codex == nil
      assert result.message =~ "401"
      assert result.auth_expired == true
      assert Codex.latest(quota_account_id!(ws.id, "codex")) == nil
    end

    test "stale access token + valid refresh token refreshes, updates auth.json atomically, and upserts quota with auth_expired: false (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "valid-refresh", "acct-123", "2026-11-01T00:00:00Z")

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer stale-access"] ->
                conn
                |> Plug.Conn.put_status(401)
                |> Req.Test.json(%{"error" => %{"code" => "token_expired"}})

              ["Bearer fresh-access"] ->
                assert ["acct-123"] = Plug.Conn.get_req_header(conn, "chatgpt-account-id")
                Req.Test.json(conn, @usage_body)
            end

          {"POST", "/oauth/token"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            params = URI.decode_query(raw)
            assert params["grant_type"] == "refresh_token"
            assert params["refresh_token"] == "valid-refresh"
            assert is_binary(params["client_id"]) and params["client_id"] != ""

            Req.Test.json(conn, %{
              "access_token" => "fresh-access",
              "refresh_token" => "rotated-refresh",
              "id_token" => "fresh-id"
            })
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.auth_expired == false
      assert result.message == nil
      assert result.codex.plan == "plus"
      assert result.codex.session.used == 42.5

      row = Codex.latest(quota_account_id!(ws.id, "codex"))
      assert row.session_used_percent == 42.5

      persisted = auth_path |> File.read!() |> Jason.decode!()
      assert persisted["auth_mode"] == "chatgpt"
      assert persisted["tokens"]["access_token"] == "fresh-access"
      assert persisted["tokens"]["refresh_token"] == "rotated-refresh"
      assert persisted["tokens"]["id_token"] == "fresh-id"
      assert persisted["tokens"]["account_id"] == "acct-123"
      assert {:ok, dt, _} = DateTime.from_iso8601(persisted["last_refresh"])
      assert DateTime.compare(dt, ~U[2026-11-01 00:00:00Z]) == :gt
      assert {:ok, %File.Stat{mode: mode}} = File.stat(auth_path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Path.wildcard(auth_path <> ".arb-*") == []
    end

    test "never overwrites auth.json when a running worker updates it while the poll refresh is in flight (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "rt-initial", "acct-123", "2026-11-01T00:00:00Z")

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer stale-access"] ->
                Plug.Conn.send_resp(conn, 401, "")

              ["Bearer " <> fresh] when fresh in ["poll-access", "worker-access"] ->
                Req.Test.json(conn, @usage_body)
            end

          {"POST", "/oauth/token"} ->
            # Simulate a running worker rotating auth.json on disk while the poll's
            # refresh HTTP request is in flight.
            File.write!(
              auth_path,
              encode_auth("worker-access", "rt-worker", "acct-123", "2026-11-14T12:00:00Z")
            )

            Req.Test.json(conn, %{
              "access_token" => "poll-access",
              "refresh_token" => "rt-poll"
            })
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.auth_expired == false
      assert result.codex.session.used == 42.5

      # The worker's rotation on disk must remain intact, never clobbered by the poll.
      persisted = auth_path |> File.read!() |> Jason.decode!()
      assert persisted["tokens"]["access_token"] == "worker-access"
      assert persisted["tokens"]["refresh_token"] == "rt-worker"
      assert persisted["last_refresh"] == "2026-11-14T12:00:00Z"
    end

    test "adopts a concurrent worker's rotation without firing credential_expired when the refresh token was already rotated on disk (bd-6yk7qi)" do
      ws = workspace!()
      auth_path = write_auth_file!("stale-access", "rt-old", "acct-123", "2026-11-01T00:00:00Z")

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer stale-access"] ->
                Plug.Conn.send_resp(conn, 401, "")

              ["Bearer worker-fresh"] ->
                Req.Test.json(conn, @usage_body)
            end

          {"POST", "/oauth/token"} ->
            # A running worker beat us to the refresh endpoint and wrote its new
            # tokens to auth.json, so our refresh attempt with rt-old gets 401.
            File.write!(
              auth_path,
              encode_auth("worker-fresh", "rt-worker", "acct-123", "2026-11-14T12:00:00Z")
            )

            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"error" => %{"code" => "refresh_token_reused"}})
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.auth_expired == false
      assert result.codex.session.used == 42.5
    end

    test "auth_expired fires only when the refresh token itself fails (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "expired-refresh", "acct-123", "2026-11-01T00:00:00Z")

      original = File.read!(auth_path)
      refresh_calls = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            Plug.Conn.send_resp(conn, 401, "")

          {"POST", "/oauth/token"} ->
            :counters.add(refresh_calls, 1, 1)

            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"error" => %{"code" => "refresh_token_expired"}})
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert :counters.get(refresh_calls, 1) == 1
      assert result.codex == nil
      assert result.message =~ "401"
      assert result.auth_expired == true
      assert File.read!(auth_path) == original
      assert Codex.latest(quota_account_id!(ws.id, "codex")) == nil
    end

    test "reloads a fresh token from disk without calling /oauth/token when a worker already refreshed auth.json (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "rt-initial", "acct-123", "2026-11-01T00:00:00Z")

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer stale-access"] ->
                # A running worker finishes its refresh before we enter the refresh lock.
                File.write!(
                  auth_path,
                  encode_auth("worker-fresh", "rt-worker", "acct-123", "2026-11-14T12:00:00Z")
                )

                Plug.Conn.send_resp(conn, 401, "")

              ["Bearer worker-fresh"] ->
                Req.Test.json(conn, @usage_body)
            end

          {"POST", "/oauth/token"} ->
            flunk(
              "/oauth/token should not be called when auth.json already holds a newer access token"
            )
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.auth_expired == false
      assert result.codex.session.used == 42.5
    end

    test "writes through a symlinked auth.json without replacing the link (bd-6yk7qi)" do
      ws = workspace!()

      real_path =
        write_auth_file!("stale-access", "valid-refresh", "acct-123", "2026-11-01T00:00:00Z")

      link_path =
        Path.join(
          System.tmp_dir!(),
          "codex_auth_link_#{System.unique_integer([:positive])}.json"
        )

      File.ln_s!(real_path, link_path)
      on_exit(fn -> File.rm(link_path) end)

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              ["Bearer stale-access"] -> Plug.Conn.send_resp(conn, 401, "")
              ["Bearer fresh-access"] -> Req.Test.json(conn, @usage_body)
            end

          {"POST", "/oauth/token"} ->
            Req.Test.json(conn, %{
              "access_token" => "fresh-access",
              "refresh_token" => "rotated-refresh"
            })
        end
      end)

      result = Codex.fetch(ws.id, auth_path: link_path)

      assert result.auth_expired == false
      assert result.codex.session.used == 42.5
      assert {:ok, ^real_path} = File.read_link(link_path)
      persisted = real_path |> File.read!() |> Jason.decode!()
      assert persisted["tokens"]["access_token"] == "fresh-access"
      assert persisted["tokens"]["refresh_token"] == "rotated-refresh"
    end

    test "a transient failure on the token refresh endpoint treats the 401 as neutral (auth_expired: false) (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "valid-refresh", "acct-123", "2026-11-01T00:00:00Z")

      original = File.read!(auth_path)

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            Plug.Conn.send_resp(conn, 401, "")

          {"POST", "/oauth/token"} ->
            Plug.Conn.send_resp(conn, 503, "")
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.codex == nil
      assert result.auth_expired == false
      assert File.read!(auth_path) == original
    end

    test "a 401 from wham/usage after a successful token refresh is treated as neutral (auth_expired: false) (bd-6yk7qi)" do
      ws = workspace!()

      auth_path =
        write_auth_file!("stale-access", "valid-refresh", "acct-123", "2026-11-01T00:00:00Z")

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/backend-api/wham/usage"} ->
            Plug.Conn.send_resp(conn, 401, "")

          {"POST", "/oauth/token"} ->
            Req.Test.json(conn, %{
              "access_token" => "fresh-access",
              "refresh_token" => "rotated-refresh"
            })
        end
      end)

      result = Codex.fetch(ws.id, auth_path: auth_path)

      assert result.codex == nil
      assert result.auth_expired == false
    end

    # bd-1fpjgx: `auth_expired` must be a dedicated flag, not something parsed
    # back out of the message text — any non-401, non-200 status produces the
    # same "temporarily unavailable (N)" message shape.
    test "a non-401 error status is not treated as an expiry signal" do
      ws = workspace!()

      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "")
      end)

      result = Codex.fetch(ws.id, credentials: creds())

      assert result.codex == nil
      assert result.message =~ "500"
      assert result.auth_expired == false
    end

    # Req's default retry sleeps 1s+2s+4s on a 5xx; the quota poll runs again
    # next cycle, so one attempt is enough (and a CI run does not crawl).
    test "a 5xx is attempted once, not retried with backoff" do
      ws = workspace!()
      calls = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.send_resp(conn, 503, "")
      end)

      {micros, result} = :timer.tc(fn -> Codex.fetch(ws.id, credentials: creds()) end)

      assert result.message =~ "503"
      assert :counters.get(calls, 1) == 1
      assert micros < 1_000_000
    end
  end

  describe "read_credentials/1" do
    test "reads access_token + account_id from a codex auth.json" do
      path = Path.join(System.tmp_dir!(), "codex_auth_#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "tokens" => %{"access_token" => "AT", "account_id" => "AID"}
        })
      )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{access_token: "AT", account_id: "AID"}} =
               Codex.read_credentials(auth_path: path)
    end

    test "errors when the file is absent" do
      assert {:error, _} = Codex.read_credentials(auth_path: "/nope/auth.json")
    end

    test "reads the Codex source home when auth_path option is not provided" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "codex_home_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      auth_file = Path.join(tmp_dir, "auth.json")

      File.write!(
        auth_file,
        Jason.encode!(%{
          "tokens" => %{"access_token" => "CH_TOKEN", "account_id" => "CH_ACCT"}
        })
      )

      prev_home = Application.get_env(:wardmast, :worker_codex_source_home)
      prev_cfg = Application.get_env(:wardmast, :codex_quota)

      # Temporarily clear the test config override so default_auth_path/0 is evaluated
      Application.put_env(:wardmast, :codex_quota, [])
      Application.put_env(:wardmast, :worker_codex_source_home, tmp_dir)

      on_exit(fn ->
        restore_env(:worker_codex_source_home, prev_home)
        restore_env(:codex_quota, prev_cfg)
        File.rm_rf(tmp_dir)
      end)

      assert {:ok, %{access_token: "CH_TOKEN", account_id: "CH_ACCT"}} =
               Codex.read_credentials([])
    end
  end

  describe "probe_auth/1" do
    setup do
      prev_http_stub = Application.get_env(:wardmast, :codex_quota_http_stub)
      Application.put_env(:wardmast, :codex_quota_http_stub, true)
      on_exit(fn -> restore_env(:codex_quota_http_stub, prev_http_stub) end)
      :ok
    end

    test "returns {:ok, 200, body} on valid credentials" do
      Req.Test.stub(@stub_name, fn conn ->
        assert ["Bearer tok-abc"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, @usage_body)
      end)

      assert {:ok, 200, body} = Codex.probe_auth(credentials: creds())
      assert is_map(body)
    end

    test "returns {:ok, 401, body} on expired credentials" do
      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "expired"})
      end)

      assert {:ok, 401, _} = Codex.probe_auth(credentials: creds())
    end

    test "returns {:error, :enoent} when auth_path is missing" do
      assert {:error, :enoent} = Codex.probe_auth(auth_path: "/nonexistent/auth.json")
    end

    test "reads credentials from the Codex source home when not specified" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "codex_home_probe_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      auth_file = Path.join(tmp_dir, "auth.json")

      File.write!(
        auth_file,
        Jason.encode!(%{
          "tokens" => %{"access_token" => "CH_TOKEN", "account_id" => "CH_ACCT"}
        })
      )

      prev_home = Application.get_env(:wardmast, :worker_codex_source_home)
      prev_cfg = Application.get_env(:wardmast, :codex_quota)

      Application.put_env(:wardmast, :codex_quota, [])
      Application.put_env(:wardmast, :worker_codex_source_home, tmp_dir)

      on_exit(fn ->
        restore_env(:worker_codex_source_home, prev_home)
        restore_env(:codex_quota, prev_cfg)
        File.rm_rf(tmp_dir)
      end)

      Req.Test.stub(@stub_name, fn conn ->
        assert ["Bearer CH_TOKEN"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, @usage_body)
      end)

      assert {:ok, 200, _} = Codex.probe_auth([])
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:wardmast, key)
  defp restore_env(key, val), do: Application.put_env(:wardmast, key, val)

  defp write_auth_file!(access_token, refresh_token, account_id, last_refresh) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex_auth_refresh_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, encode_auth(access_token, refresh_token, account_id, last_refresh))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp encode_auth(access_token, refresh_token, account_id, last_refresh) do
    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" => "id-0",
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "account_id" => account_id
      },
      "last_refresh" => last_refresh
    })
  end
end
