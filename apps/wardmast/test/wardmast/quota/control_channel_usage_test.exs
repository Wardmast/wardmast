defmodule Wardmast.Quota.ControlChannelUsageTest do
  @moduledoc """
  bd-a2zrh0 / bd-6y4pj6: `Wardmast.Quota.capture_oauth_usage/2` on an account
  with a quota grant (`:cli_credentials_path`) polls `/api/oauth/usage` over HTTP
  with the grant file's access token and never spawns `claude` against the
  grant's config dir: `Wardmast.Quota.GrantRefresher` is its only refresher.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Agents.Claude.ControlChannel
  alias Wardmast.Quota
  alias Wardmast.Test.ClaudeControlStub

  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = context do
    Application.put_env(:wardmast, :oauth_usage_http_stub, true)
    Application.put_env(:wardmast, ControlChannel, enabled: true)
    Req.Test.set_req_test_to_shared(context)

    on_exit(fn -> Application.put_env(:wardmast, ControlChannel, enabled: false) end)

    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "control-usage"})

    grant_dir = Path.join(tmp_dir, "quota-claude")
    File.mkdir_p!(grant_dir)

    File.write!(
      Path.join(grant_dir, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "grant-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: grant_dir})

    on_exit(fn -> Wardmast.Quota.OAuthUsage.reset_cooldown!(account.id) end)

    test_pid = self()

    Req.Test.stub(Wardmast.Quota.OAuthUsage.HTTP, fn conn ->
      send(test_pid, {:http_usage, Plug.Conn.get_req_header(conn, "authorization")})
      Req.Test.json(conn, %{"five_hour" => %{"utilization" => 77}})
    end)

    # A wrapper that records the config dir the CLI is pointed at, then runs
    # the stub CLI.
    stub = ClaudeControlStub.write!(tmp_dir)
    seen = Path.join(tmp_dir, "config-dir-seen")
    wrapper = Path.join(tmp_dir, "wrap.sh")
    File.write!(wrapper, ~s(#!/bin/sh\necho "$CLAUDE_CONFIG_DIR" > #{seen}\nexec sh "$@"\n))

    %{account: account, grant_dir: grant_dir, stub: stub, wrapper: wrapper, seen: seen}
  end

  defp capture(ctx, mode, extra \\ []) do
    Quota.capture_oauth_usage(
      ctx.account.id,
      control_channel:
        [control_command: ["sh", ctx.wrapper, ctx.stub, mode], timeout_ms: 2_000] ++ extra
    )
  end

  # bd-6y4pj6: the grant is refreshed by exactly one process, `GrantRefresher`.
  # A `claude` spawned here against the grant's config dir refreshes (and, when
  # its rotation races the refresher's, blanks) that same file; that is what
  # re-blinded the quota poll ~32h after a re-login. So a poll on a quota grant
  # reads the file's access token over HTTP and never spawns the CLI, whatever
  # the channel could have answered.
  for mode <- ~w(ok cli_2_1_317 statusline_shape no_usage exit usage_hang) do
    test "#{mode}: a quota-grant poll never spawns the CLI, it reads the grant over HTTP", ctx do
      assert {:ok, snapshot} = capture(ctx, unquote(mode), timeout_ms: 300)

      assert_received {:http_usage, ["Bearer grant-token"]}
      # The HTTP stub's five_hour utilization is 77, not the control stub's 42.
      assert_in_delta snapshot.utilization_5h, 0.77, 0.001
      refute File.exists?(ctx.seen)
    end
  end

  test "a disabled channel is never spawned", ctx do
    Application.put_env(:wardmast, ControlChannel, enabled: false)
    assert {:ok, snapshot} = capture(ctx, "ok")
    assert_in_delta snapshot.utilization_5h, 0.77, 0.001
    refute File.exists?(ctx.seen)
  end
end
