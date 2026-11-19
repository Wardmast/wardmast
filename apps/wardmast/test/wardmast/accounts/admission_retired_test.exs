defmodule Wardmast.Accounts.AdmissionRetiredTest do
  @moduledoc """
  DC12 (bd-b3u00u): the `legacy` and `shadow` admission modes are retired, so
  admission is always the budget walk's (`enforce`). There is no installation
  key and no per-account override left to configure.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Settings

  test "the installation scheduler_admission key is gone" do
    refute "scheduler_admission" in Settings.Registry.keys()
    refute function_exported?(Settings, :scheduler_admission, 0)
    refute function_exported?(Settings, :set_scheduler_admission, 1)
  end

  test "the per-account admission override is gone" do
    refute :admission in Ash.Resource.Info.attribute_names(ProviderAccount)
    refute Code.ensure_loaded?(Wardmast.Accounts.AdmissionMode)

    {:ok, account} = Ash.create(ProviderAccount, %{provider: :claude, slug: "ar-edit"})

    assert {:error, _} = Accounts.edit_account(account.id, %{"admission" => "enforce"})
  end
end
