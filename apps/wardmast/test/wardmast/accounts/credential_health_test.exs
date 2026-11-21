defmodule Wardmast.Accounts.CredentialHealthTest do
  @moduledoc """
  Per-account credential health (bd-6y4pj6): the kind of each active credential,
  whether it is healthy, and when it expires where that is known — what
  `ward server doctor`, `ward account list` and the dashboard show so a lapsing
  login is seen before the quota goes blind.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Accounts.CredentialHealth

  @moduletag :tmp_dir

  @day_ms 86_400_000

  defp account!(slug \\ "health") do
    {:ok, account} = Accounts.create_account(%{provider: :claude, slug: slug})
    account
  end

  defp write_grant!(dir, oauth) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
  end

  defp now_ms, do: System.system_time(:millisecond)

  test "an account with no credentials has no entries" do
    assert CredentialHealth.for_account(account!()) == []
  end

  test "a fresh setup token is healthy, with an estimated ~1 year expiry" do
    account = account!()

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{
        kind: :oauth_token,
        secret: "sk-ant-oat01-SECRET",
        env_var: "CLAUDE_CODE_OAUTH_TOKEN"
      })

    assert [entry] = CredentialHealth.for_account(account)
    assert entry.kind == :setup_token
    assert entry.health == :ok
    assert entry.expiry == :estimated
    assert %DateTime{} = entry.expires_at
    assert DateTime.diff(entry.expires_at, DateTime.utc_now(), :day) in 360..366
    refute inspect(entry) =~ "SECRET"
  end

  test "a setup token near its ~1 year life is expiring and names the renewal command" do
    account = account!()

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{
        kind: :oauth_token,
        secret: "tok",
        env_var: "CLAUDE_CODE_OAUTH_TOKEN"
      })

    later = DateTime.add(DateTime.utc_now(), 340 * 86_400, :second)
    [entry] = CredentialHealth.for_account(account, now: later)

    assert entry.health == :expiring
    assert entry.relogin =~ "claude setup-token"
    assert entry.relogin =~ "arb account rotate claude:health --kind oauth_token"
  end

  test "a quota grant reports the refresh token's expiry and is healthy when the file is good",
       %{tmp_dir: tmp_dir} do
    account = account!()
    dir = Path.join(tmp_dir, "quota-claude")

    write_grant!(dir, %{
      "accessToken" => "a",
      "refreshToken" => "r",
      "expiresAt" => now_ms() + 4 * 3_600_000,
      "refreshTokenExpiresAt" => now_ms() + 20 * @day_ms
    })

    {:ok, _} = Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

    assert [entry] = CredentialHealth.for_account(account)
    assert entry.kind == :quota_grant
    assert entry.health == :ok
    assert entry.expiry == :known
    assert DateTime.diff(entry.expires_at, DateTime.utc_now(), :day) in 19..20
    assert %DateTime{} = entry.access_expires_at
  end

  test "a quota grant whose refresh token lapses within 2 days is expiring, with the login command",
       %{tmp_dir: tmp_dir} do
    account = account!()
    dir = Path.join(tmp_dir, "quota-claude")

    write_grant!(dir, %{
      "accessToken" => "a",
      "expiresAt" => now_ms() + 3_600_000,
      "refreshTokenExpiresAt" => now_ms() + @day_ms
    })

    {:ok, _} = Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

    assert [entry] = CredentialHealth.for_account(account)
    assert entry.health == :expiring
    assert entry.relogin == "CLAUDE_CONFIG_DIR=#{dir} claude auth login"
  end

  test "a quota grant whose file is gone is failing, with the login command", %{tmp_dir: tmp_dir} do
    account = account!()
    dir = Path.join(tmp_dir, "quota-claude")
    write_grant!(dir, %{"accessToken" => "a", "expiresAt" => now_ms() + 3_600_000})
    {:ok, _} = Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})
    File.rm!(Path.join(dir, ".credentials.json"))

    assert [entry] = CredentialHealth.for_account(account)
    assert entry.health == :failing
    assert entry.detail =~ "enoent"
    assert entry.relogin =~ "claude auth login"
  end

  test "a quota grant whose access token lapsed with nobody renewing it is expired",
       %{tmp_dir: tmp_dir} do
    account = account!()
    dir = Path.join(tmp_dir, "quota-claude")
    write_grant!(dir, %{"accessToken" => "a", "expiresAt" => now_ms() - 3_600_000})
    {:ok, _} = Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: dir})

    assert [entry] = CredentialHealth.for_account(account)
    assert entry.health == :expired
  end

  test "summary/1 is the worst health among the entries" do
    assert CredentialHealth.summary([%{health: :ok}, %{health: :expiring}]) == :expiring
    assert CredentialHealth.summary([%{health: :ok}, %{health: :failing}]) == :failing
    assert CredentialHealth.summary([]) == :none
  end

  test "to_map/1 renders JSON-safe values" do
    account = account!()

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{
        kind: :oauth_token,
        secret: "tok",
        env_var: "CLAUDE_CODE_OAUTH_TOKEN"
      })

    [entry] = CredentialHealth.for_account(account)

    map = CredentialHealth.to_map(entry)
    assert map.kind == "setup_token"
    assert map.health == "ok"
    assert is_binary(map.expires_at)
    assert {:ok, _} = Jason.encode(map)
  end
end
