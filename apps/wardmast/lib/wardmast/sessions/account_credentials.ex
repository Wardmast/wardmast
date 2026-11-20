defmodule Wardmast.Sessions.AccountCredentials do
  @moduledoc """
  Which provider account a coordinator session authenticates as (bd-oqkeso).

  Mode-B seeding used to copy the **server OS user's** `~/.claude`
  (`Wardmast.Sessions.Provisioning.credentials_source/1`). The dashboard login
  relay (`Wardmast.Accounts.LoginRunner`) writes each connected account's grant
  to its own dir, `<accounts_root>/<provider>-<slug>/`, which a session never
  read — so a customer who only connected an account in the UI launched an
  unauthenticated session.

  This module is the resolver in between. `resolve/3` turns an account ref (a
  slug, `provider:slug`, or the account id) into that per-account config dir —
  the `source_dir` the existing copy-seeding (`ConfigDir.seed_credentials/2`,
  always a **copy**, never a symlink) reads from — after checking, before any
  session scaffolding exists, that the account:

    * exists, is enabled, and belongs to the session's provider;
    * has a readable `.credentials.json` holding an OAuth grant;
    * is not lapsed: an access token past `expiresAt` is fine while the grant
      carries a `refreshToken` (Claude Code renews it at start), and refused
      when it does not.

  Each refusal is `{:error, {tag, message}}` where the message names the fix
  (connect, enable, or log in again from the dashboard). Messages carry the
  account slug and the dir — never a credential value; the file is parsed only
  for the presence and expiry of its fields.

  `options/2` is the launch form's account picker: the workspace's linked,
  enabled accounts for the provider, or — when the workspace links none, which
  is exactly the "only connected an account in the UI" customer — every enabled
  account of the provider.
  """

  require Ash.Query

  alias Wardmast.Accounts
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.WorkspaceProviderAccount
  alias Wardmast.Config.Paths

  @credentials_file ".credentials.json"

  @type error ::
          {:account_not_found
           | :account_disabled
           | :account_provider_mismatch
           | :account_credential_missing
           | :account_credential_expired, String.t()}

  @doc """
  The config dir to seed a `provider` session's credentials from, for the
  account `ref`.

  Options: `:accounts_root` (default `Wardmast.Config.Paths.accounts_root/0`)
  and `:now_ms` (tests).
  """
  @spec resolve(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def resolve(provider, ref, opts \\ []) when is_atom(provider) and is_binary(ref) do
    root = Keyword.get_lazy(opts, :accounts_root, &Paths.accounts_root/0)

    with {:ok, account} <- fetch_account(provider, ref),
         :ok <- ensure_enabled(account),
         :ok <- ensure_provider(account, provider),
         dir = Path.join(root, "#{account.provider}-#{account.slug}"),
         :ok <- check_credential(account, dir, Keyword.get(opts, :now_ms)) do
      {:ok, dir}
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
  # path is not a slug — and `get_account/1` is a DB lookup, never a path join,
  # so the dir below is only ever built from a stored account's own slug.
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

  defp check_credential(%ProviderAccount{slug: slug}, dir, now_ms) do
    path = Path.join(dir, @credentials_file)

    case read_grant(path) do
      {:ok, grant} -> check_expiry(slug, dir, grant, now_ms || System.os_time(:millisecond))
      :error -> {:error, {:account_credential_missing, missing_message(slug, dir)}}
    end
  end

  # Parsed only for field presence / expiry; the values never leave this
  # function (no logging, no error term carries them).
  defp read_grant(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"claudeAiOauth" => %{} = oauth}} <- Jason.decode(raw),
         token when is_binary(token) and token != "" <- oauth["accessToken"] do
      {:ok, oauth}
    else
      _ -> :error
    end
  end

  defp check_expiry(slug, dir, grant, now_ms) do
    expires_at = grant["expiresAt"]
    refreshable? = is_binary(grant["refreshToken"]) and grant["refreshToken"] != ""

    if is_integer(expires_at) and expires_at <= now_ms and not refreshable? do
      {:error,
       {:account_credential_expired,
        "The stored login for account #{inspect(slug)} has expired and cannot be renewed " <>
          "(#{dir}). Log in again from the dashboard (Accounts → #{slug} → Log in), then relaunch."}}
    else
      :ok
    end
  end

  defp missing_message(slug, dir) do
    "Account #{inspect(slug)} has no usable login: no readable #{@credentials_file} in #{dir}. " <>
      "Log in to it from the dashboard (Accounts → #{slug} → Log in), then relaunch."
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
