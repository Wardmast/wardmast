defmodule Wardmast.Sessions.AccountCredentials do
  @moduledoc """
  Which provider account a coordinator session authenticates as (bd-oqkeso).

  A session used to be seeded a *copy* of the account dir's
  `.credentials.json` (`<accounts_root>/<provider>-<slug>/`, written by the
  dashboard login relay). That file is a **rotating** OAuth grant, and the quota
  poller (`Wardmast.Quota.GrantRefresher`) refreshes it; a second holder
  refreshing the copy rotated the refresh token out from under it and
  invalidated the grant — the 2026-11-20 22:47Z "quota grant needs re-login"
  outage (bd-6y4pj6).

  `resolve/3` therefore hands a session the account's **setup token** (the
  `claude setup-token` secret, an `:oauth_token` credential: about a year,
  non-rotating — the same credential workers use), never a file. It checks,
  before any session scaffolding exists, that the account:

    * exists, is enabled, and belongs to the session's provider;
    * has an active setup token.

  Each refusal is `{:error, {tag, message}}` where the message names the fix.
  Messages carry the account slug — never a credential value. Nothing in this
  module opens a credentials file.

  `options/2` is the launch form's account picker: the workspace's linked,
  enabled accounts for the provider, or — when the workspace links none, which
  is exactly the "only connected an account in the UI" customer — every enabled
  account of the provider.
  """

  require Ash.Query

  alias Wardmast.Accounts
  alias Wardmast.Accounts.Credentials
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.WorkspaceProviderAccount

  @type error ::
          {:account_not_found
           | :account_disabled
           | :account_provider_mismatch
           | :account_setup_token_missing, String.t()}

  @doc """
  The setup token a `provider` session authenticates with, for the account
  `ref` (a slug, `provider:slug`, or the account id).
  """
  @spec resolve(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def resolve(provider, ref, _opts \\ []) when is_atom(provider) and is_binary(ref) do
    with {:ok, account} <- fetch_account(provider, ref),
         :ok <- ensure_enabled(account),
         :ok <- ensure_provider(account, provider) do
      setup_token(account)
    end
  end

  @doc """
  The accounts the launch form offers for `provider` in `workspace_id`: the
  workspace's linked accounts, else every account of the provider — enabled
  only, sorted by slug.
  """
  @spec options(String.t() | nil, atom()) :: [ProviderAccount.t()]
  def options(workspace_id, provider) when is_atom(provider) do
    enabled = enabled_accounts(provider)

    case linked_ids(workspace_id, provider) do
      [] -> enabled
      ids -> Enum.filter(enabled, &(&1.id in ids))
    end
  end

  # -- account -----------------------------------------------------------------

  # A bare slug is qualified with the session's provider: slugs are only
  # unique within one, and "work" must not turn ambiguous because a codex
  # account is also called "work". Anything with a separator that could walk a
  # path is not a slug, and `get_account/1` is a DB lookup, never a path join.
  defp fetch_account(provider, ref) do
    lookup = if bare_slug?(ref), do: "#{provider}:#{ref}", else: ref

    case Accounts.get_account(lookup) do
      {:ok, %ProviderAccount{} = account} ->
        {:ok, account}

      {:error, _} ->
        {:error,
         {:account_not_found,
          "No #{provider} account #{inspect(ref)} is connected to this install. " <>
            "Connect it from the dashboard (Accounts → Add account → Log in), or pick another account."}}
    end
  end

  defp bare_slug?(ref), do: not String.contains?(ref, ":") and not uuid?(ref)

  defp uuid?(ref), do: match?({:ok, _}, Ecto.UUID.cast(ref))

  defp ensure_enabled(%ProviderAccount{enabled: true}), do: :ok

  defp ensure_enabled(%ProviderAccount{slug: slug}) do
    {:error,
     {:account_disabled,
      "Account #{inspect(slug)} is parked (disabled). " <>
        "Re-enable it from the dashboard (Accounts → #{slug} → Enable), or pick another account."}}
  end

  defp ensure_provider(%ProviderAccount{provider: provider}, provider), do: :ok

  defp ensure_provider(%ProviderAccount{provider: actual, slug: slug}, expected) do
    {:error,
     {:account_provider_mismatch,
      "Account #{inspect(slug)} is a #{actual} account, not a #{expected} one. " <>
        "Pick a #{expected} account."}}
  end

  # -- credential --------------------------------------------------------------

  defp setup_token(%ProviderAccount{id: id, provider: provider, slug: slug}) do
    case Credentials.account_setup_token(id) do
      {:ok, token} ->
        {:ok, token}

      :none ->
        {:error,
         {:account_setup_token_missing,
          "Account #{inspect(slug)} has no setup token, and a session never borrows the " <>
            "account's rotating login (it would race the quota poller and invalidate it). " <>
            "Run `claude setup-token` on a machine you are logged in to, then store the token " <>
            "with `arb account rotate #{provider}:#{slug} --kind oauth_token --secret <token>`."}}
    end
  end

  # -- options -----------------------------------------------------------------

  defp enabled_accounts(provider) do
    ProviderAccount
    |> Ash.Query.filter(provider == ^provider and enabled == true and is_nil(deleted_at))
    |> Ash.Query.sort(slug: :asc)
    |> Ash.read()
    |> case do
      {:ok, accounts} -> accounts
      _ -> []
    end
  end

  defp linked_ids(workspace_id, provider) when is_binary(workspace_id) and workspace_id != "" do
    with {:ok, _} <- Ash.Type.UUID.cast_input(workspace_id, []),
         {:ok, links} <-
           WorkspaceProviderAccount
           |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
           |> Ash.read() do
      Enum.map(links, & &1.provider_account_id)
    else
      _ -> []
    end
  end

  defp linked_ids(_, _), do: []
end
