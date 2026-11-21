defmodule WardmastWeb.Api.AccountJSON do
  @moduledoc """
  Render functions for `Wardmast.Accounts.ProviderAccount` and friends.

  The wire shape is `Wardmast.Accounts.Serializer`, shared with the MCP
  `account_list` / `account_show` tools. `show` includes the account's
  credentials (kind/fingerprint/active only — **never** the secret value, per
  P11's acceptance bar) and attached workspaces, so `arb account show <slug>`
  is a single round trip.
  """

  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.Serializer

  def index(%{accounts: accounts}),
    do: %{data: Enum.map(accounts, &data(&1, credential_health?: true))}

  def show(%{account: account}), do: data(account, detailed?: true)

  def attach(%{link: link}), do: Serializer.link(link)

  def credential(%{credential: credential}), do: Serializer.credential(credential)

  def data(%ProviderAccount{} = account, opts \\ []), do: Serializer.data(account, opts)
end
