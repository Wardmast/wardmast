defmodule Wardmast.Sessions.AccountCredentialsTest do
  @moduledoc """
  A session authenticates as a chosen provider account (bd-oqkeso): the account
  resolves to the login relay's `<accounts_root>/claude-<slug>` dir, and a
  missing / unreadable / lapsed credential is refused with a message naming the
  fix instead of handing the session an unauthenticated config dir.
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

  defp write_credentials!(root, slug, oauth) do
    dir = Path.join(root, "claude-#{slug}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".credentials.json"), Jason.encode!(%{"claudeAiOauth" => oauth}))
    dir
  end

  defp future_ms, do: System.os_time(:millisecond) + 3_600_000
  defp past_ms, do: System.os_time(:millisecond) - 3_600_000

  describe "resolve/2" do
    test "returns the login relay's per-account dir for a connected account", %{
      accounts_root: root
    } do
      account!("work")

      dir =
        write_credentials!(root, "work", %{"accessToken" => @token, "expiresAt" => future_ms()})

      assert {:ok, ^dir} = AccountCredentials.resolve(:claude, "work")
    end

    test "accepts a provider-qualified ref and the account id", %{accounts_root: root} do
      account = account!("work")

      dir =
        write_credentials!(root, "work", %{"accessToken" => @token, "expiresAt" => future_ms()})

      assert {:ok, ^dir} = AccountCredentials.resolve(:claude, "claude:work")
      assert {:ok, ^dir} = AccountCredentials.resolve(:claude, account.id)
    end

    test "an expired access token is fine while a refresh token can renew it", %{
      accounts_root: root
    } do
      account!("work")

      dir =
        write_credentials!(root, "work", %{
          "accessToken" => @token,
          "refreshToken" => "r",
          "expiresAt" => past_ms()
        })

      assert {:ok, ^dir} = AccountCredentials.resolve(:claude, "work")
    end

    test "an unknown account names the fix" do
      assert {:error, {:account_not_found, message}} =
               AccountCredentials.resolve(:claude, "ghost")

      assert message =~ "ghost"
      assert message =~ "Accounts"
    end

    test "a parked account is refused" do
      account!("parked", %{enabled: false})

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

    test "an account that never logged in names the login fix", %{accounts_root: root} do
      account!("fresh")

      assert {:error, {:account_credential_missing, message}} =
               AccountCredentials.resolve(:claude, "fresh")

      assert message =~ "fresh"
      assert message =~ "Log in"
      # the path is operator-facing context; the credential itself never is
      assert message =~ Path.join(root, "claude-fresh")
    end

    test "an unreadable credential file is treated as missing", %{accounts_root: root} do
      account!("junk")
      dir = Path.join(root, "claude-junk")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".credentials.json"), "not json " <> @token)

      assert {:error, {:account_credential_missing, message}} =
               AccountCredentials.resolve(:claude, "junk")

      refute message =~ @token
    end

    test "a lapsed credential with no refresh token names the re-login fix", %{
      accounts_root: root
    } do
      account!("old")
      write_credentials!(root, "old", %{"accessToken" => @token, "expiresAt" => past_ms()})

      assert {:error, {:account_credential_expired, message}} =
               AccountCredentials.resolve(:claude, "old")

      assert message =~ "old"
      assert message =~ "Log in again"
      refute message =~ @token
    end

    test "a slug that tries to leave the accounts root never resolves a path" do
      assert {:error, {:account_not_found, _}} = AccountCredentials.resolve(:claude, "../../etc")
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
