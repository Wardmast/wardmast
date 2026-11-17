defmodule Wardmast.Accounts.ServiceAccountCredentialTest do
  @moduledoc """
  The `:service_account` credential kind (bd-b2t0kw): an `antigravity` account's
  Google Cloud service-account JSON key, which agy reads as Application Default
  Credentials (`AGY_ADC_AUTH=true`, `GOOGLE_APPLICATION_CREDENTIALS=<file>`). The key
  is stored encrypted, is never projected into a spawn env as a variable (a worker
  gets it as a file), and is read back only by `Credentials.workspace_service_account/1`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Accounts.Credentials
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.ProviderCredential
  alias Wardmast.Accounts.WorkspaceProviderAccount
  alias Wardmast.Tasks.Workspace

  @private_key "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfakefakefake\n-----END PRIVATE KEY-----\n"

  defp key_json(overrides \\ %{}) do
    %{
      "type" => "service_account",
      "project_id" => "arb-agy-test",
      "private_key_id" => "0123456789abcdef0123456789abcdef01234567",
      "private_key" => @private_key,
      "client_email" => "arb-agy@arb-agy-test.iam.gserviceaccount.com",
      "client_id" => "100000000000000000001",
      "token_uri" => "https://oauth2.googleapis.com/token"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp account!(slug, attrs \\ %{}) do
    Ash.create!(ProviderAccount, Map.merge(%{provider: :antigravity, slug: slug}, attrs))
  end

  defp workspace_on!(account, name) do
    ws = Ash.create!(Workspace, %{name: name})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :antigravity,
      provider_account_id: account.id
    })

    ws
  end

  defp rotate!(account, json \\ key_json()) do
    {:ok, credential} =
      Accounts.rotate_credential(account.id, %{"kind" => "service_account", "secret" => json})

    credential
  end

  describe "Accounts.rotate_credential/2 with kind service_account" do
    test "stores the key encrypted at rest, filed under GOOGLE_APPLICATION_CREDENTIALS" do
      account = account!("agy-sa")
      json = key_json()

      assert {:ok, credential} =
               Accounts.rotate_credential(account.id, %{
                 "kind" => "service_account",
                 "secret" => json
               })

      assert credential.kind == :service_account
      assert credential.env_var == "GOOGLE_APPLICATION_CREDENTIALS"
      assert credential.active

      {:ok, stored} = Ash.get(ProviderCredential, credential.id)
      assert ProviderCredential.secret(stored) == json

      # What is on disk is ciphertext: neither the key nor the account it names is in
      # the column, raw or base64-decoded.
      %{rows: rows} = Wardmast.Repo.query!("SELECT encrypted_secret FROM provider_credentials")
      columns = for [value] <- rows, is_binary(value), do: value
      assert columns != []

      for column <- columns, form <- [column, Base.decode64!(column)] do
        refute form =~ "PRIVATE KEY"
        refute form =~ "arb-agy@arb-agy-test.iam.gserviceaccount.com"
      end
    end

    test "a second key retires the first: one active service_account row" do
      account = account!("agy-sa-rotate")
      first = rotate!(account)
      second = rotate!(account, key_json(%{"private_key_id" => String.duplicate("f", 40)}))

      assert Ash.get!(ProviderCredential, first.id).active == false
      assert Ash.get!(ProviderCredential, second.id).active == true
    end

    test "refuses what is not a service-account key, without echoing it" do
      account = account!("agy-sa-bad")

      for {secret, reason} <- [
            {"not json at all", :not_json},
            {Jason.encode!(["a", "list"]), :not_json_object},
            {key_json(%{"type" => "authorized_user"}), :not_a_service_account},
            {key_json(%{"private_key" => ""}), {:missing_field, "private_key"}},
            {key_json(%{"client_email" => nil}), {:missing_field, "client_email"}},
            {key_json(%{"project_id" => "  "}), {:missing_field, "project_id"}}
          ] do
        assert {:error, {:invalid_service_account_key, ^reason}} =
                 Accounts.rotate_credential(account.id, %{
                   "kind" => "service_account",
                   "secret" => secret
                 })
      end

      assert Ash.read!(ProviderCredential) |> Enum.filter(&(&1.provider_account_id == account.id)) ==
               []
    end

    test "is an antigravity credential only" do
      claude = account!("claude-sa", %{provider: :claude})

      assert {:error, {:kind_not_supported, :service_account, :claude}} =
               Accounts.rotate_credential(claude.id, %{
                 "kind" => "service_account",
                 "secret" => key_json()
               })
    end
  end

  describe "the read side" do
    test "a key is never projected into a spawn env as a variable" do
      account = account!("agy-sa-no-env")
      rotate!(account)
      ws = workspace_on!(account, "agy-sa-no-env-ws")

      assert Credentials.workspace_pairs(ws.id) == []
      assert Credentials.workspace_pairs(ws.id, :antigravity) == []
      assert Credentials.install_credential("GOOGLE_APPLICATION_CREDENTIALS") == :none
    end

    test "workspace_service_account/1 is the linked account's active key" do
      account = account!("agy-sa-read")
      ws = workspace_on!(account, "agy-sa-read-ws")
      assert Credentials.workspace_service_account(ws.id) == :none

      rotate!(account)
      newer = key_json(%{"private_key_id" => String.duplicate("e", 40)})
      rotate!(account, newer)

      assert Credentials.workspace_service_account(ws.id) == {:ok, newer}
      assert Credentials.workspace_service_account?(ws.id)
    end

    test "a parked account, an unlinked workspace and a blank id have none" do
      account = account!("agy-sa-parked")
      rotate!(account)
      ws = workspace_on!(account, "agy-sa-parked-ws")
      Ash.update!(account, %{enabled: false})

      assert Credentials.workspace_service_account(ws.id) == :none
      refute Credentials.workspace_service_account?(ws.id)

      other = Ash.create!(Workspace, %{name: "agy-sa-unlinked-ws"})
      assert Credentials.workspace_service_account(other.id) == :none
      assert Credentials.workspace_service_account(nil) == :none
      assert Credentials.workspace_service_account("not-a-uuid") == :none
    end

    test "service_account_configured?/0: is there any key a run could be handed" do
      refute Credentials.service_account_configured?()

      account = account!("agy-sa-any")
      rotate!(account)
      # A key on an account no workspace uses is no key a run can carry.
      refute Credentials.service_account_configured?()

      workspace_on!(account, "agy-sa-any-ws")
      assert Credentials.service_account_configured?()

      Ash.update!(account, %{enabled: false})
      refute Credentials.service_account_configured?()
    end
  end
end
