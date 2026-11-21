defmodule Wardmast.Sessions.AccountCredentialsTest do
  @moduledoc """
  A session authenticates as a chosen provider account (bd-oqkeso) by that
  account's setup token (bd-6y4pj6) — never by a copy of the account dir's
  rotating `.credentials.json`, which the quota poller owns. An account with no
  setup token is refused with a message naming the fix.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Sessions.AccountCredentials
  alias Wardmast.Test.SessionEnv

  @token "sk-ant-oat01-ACCOUNT-CREDENTIALS-TEST"

  setup do
    env = SessionEnv.sandbox("account-credentials")
    {:ok, accounts_root: env[:accounts_root]}
  end

  defp account!(slug, attrs \\ %{}) do
    {:ok, account} = Accounts.create_account(Map.merge(%{provider: :claude, slug: slug}, attrs))
    account
  end

  defp setup_token!(account, token \\ @token) do
    Ash.create!(Wardmast.Accounts.ProviderCredential, %{
      provider_account_id: account.id,
      kind: :oauth_token,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-2690",
      secret: token
    })
  end

  defp write_credentials!(root, slug, oauth) do
    dir = Path.join(root, "claude-#{slug}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
    dir
  end

  defp future_ms, do: System.os_time(:millisecond) + 3_600_000

  describe "resolve/3 (bd-6y4pj6: the setup token, never a copy of the grant)" do
    test "returns the account's setup token", %{accounts_root: root} do
      account = account!("work")
      setup_token!(account)
      # A rotating grant on disk is irrelevant — and is never read.
      write_credentials!(root, "work", %{"accessToken" => "ROTATING", "refreshToken" => "r"})

      assert {:ok, @token} = AccountCredentials.resolve(:claude, "work")
    end

    test "accepts a provider-qualified ref and the account id" do
      account = account!("work")
      setup_token!(account)

      assert {:ok, @token} = AccountCredentials.resolve(:claude, "claude:work")
      assert {:ok, @token} = AccountCredentials.resolve(:claude, account.id)
    end

    test "an account with only a rotating grant on disk is refused with the setup-token fix",
         %{accounts_root: root} do
      account!("grant-only")

      write_credentials!(root, "grant-only", %{
        "accessToken" => @token,
        "refreshToken" => "r",
        "expiresAt" => future_ms()
      })

      assert {:error, {:account_setup_token_missing, message}} =
               AccountCredentials.resolve(:claude, "grant-only")

      assert message =~ "grant-only"
      assert message =~ "claude setup-token"
      assert message =~ "arb account rotate claude:grant-only --kind oauth_token"
      refute message =~ @token
    end

    test "an unknown account names the fix" do
      assert {:error, {:account_not_found, message}} =
               AccountCredentials.resolve(:claude, "ghost")

      assert message =~ "ghost"
      assert message =~ "Accounts"
    end

    test "a parked account is refused" do
      account = account!("parked", %{enabled: false})
      setup_token!(account)

      assert {:error, {:account_disabled, message}} =
               AccountCredentials.resolve(:claude, "parked")

      assert message =~ "parked"
      assert message =~ "enable"
    end

    test "an account of another provider is refused" do
      {:ok, _} = Accounts.create_account(%{provider: :codex, slug: "cx"})

      assert {:error, {:account_provider_mismatch, message}} =
               AccountCredentials.resolve(:claude, "codex:cx")

      assert message =~ "codex"
    end

    test "a slug that tries to leave the accounts root never resolves a path" do
      assert {:error, {:account_not_found, _}} = AccountCredentials.resolve(:claude, "../../etc")
    end

    test "has no path that returns or reads a credentials file" do
      refute function_exported?(AccountCredentials, :credentials_dir, 2)
      refute File.read!("lib/wardmast/sessions/account_credentials.ex") =~ ".credentials.json\""
    end
  end

  describe "options/2" do
    test "lists the workspace's linked, enabled accounts for the provider" do
      ws =
        Ash.create!(Wardmast.Tasks.Workspace, %{
          name: "acct-ws-#{System.unique_integer([:positive])}"
        })

      linked = account!("linked")
      _other = account!("other")
      _parked = account!("parked", %{enabled: false})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, linked.id)

      assert [%{slug: "linked"}] = AccountCredentials.options(ws.id, :claude)
    end

    test "falls back to every enabled account when the workspace links none" do
      account!("a")
      account!("b")
      _parked = account!("parked", %{enabled: false})

      assert ["a", "b"] =
               :claude |> then(&AccountCredentials.options(nil, &1)) |> Enum.map(& &1.slug)
    end
  end
end
