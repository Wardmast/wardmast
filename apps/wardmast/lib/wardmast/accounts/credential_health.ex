defmodule Wardmast.Accounts.CredentialHealth do
  @moduledoc """
  Credential health per provider account (bd-6y4pj6): what kind of credential
  each active row is, whether it is healthy, and when it expires where that is
  known. `ward server doctor`, `ward account list` and the dashboard all render
  this, so a lapsing login is seen *before* the quota poll goes blind.

  Entry kinds, and what "expiry" means for each:

    * `:setup_token` — the `claude setup-token` secret (an `:oauth_token`
      credential): non-rotating, what sessions and workers authenticate with.
      Anthropic gives it about a year; the real expiry is not exposed, so
      `expires_at` is the row's creation plus #{365} days and `expiry` is
      `:estimated`. `:expiring` within #{30} days.
    * `:quota_grant` — the quota poller's dedicated, rotating `claude` login
      (a `:cli_credentials_path` credential,
      `Wardmast.Quota.GrantFile`). `expires_at` is its **refresh token's**
      expiry (`:known`, when the file carries it): past that the CLI cannot renew
      the grant and a re-login is needed. `access_expires_at` is the short
      (~8h) access token. `:failing` when the file is unreadable or
      `Wardmast.Quota.GrantRefresher` reports a failed refresh, `:expiring`
      within #{2} days of the refresh token's expiry, `:expired` when the
      access token has lapsed with nothing renewing it.
    * `:stored_usage_token` — a legacy `:cli_credentials_file` secret; `:unknown`.
    * `:api_key` — an API key; `:ok`, no expiry.

  Health, worst first: `:failing`, `:expired`, `:expiring`, `:pending`, `:unknown`,
  `:ok`. Entries carry `relogin` — the exact command that fixes a non-`:ok`
  credential. Secrets are never returned.
  """

  require Ash.Query
  require Logger

  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.ProviderCredential
  alias Wardmast.Quota.GrantFile
  alias Wardmast.Quota.GrantRefresher

  @setup_token_life_days 365
  @setup_token_warning_days 30
  @refresh_token_warning_ms 2 * 24 * 3_600_000

  @health_rank %{failing: 5, expired: 4, expiring: 3, pending: 2, unknown: 1, ok: 0}

  @type health :: :ok | :expiring | :expired | :failing | :pending | :unknown
  @type entry :: %{
          required(:kind) => atom(),
          required(:health) => health(),
          required(:expiry) => :known | :estimated | :unknown,
          required(:expires_at) => DateTime.t() | nil,
          required(:access_expires_at) => DateTime.t() | nil,
          required(:detail) => String.t(),
          required(:relogin) => String.t() | nil
        }

  @doc """
  The health of every active credential of `account`. Options: `:now` (tests),
  `:refresher` (the `GrantRefresher` to ask, default its registered name).
  """
  @spec for_account(ProviderAccount.t(), keyword()) :: [entry()]
  def for_account(%ProviderAccount{id: id} = account, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    refresher = Keyword.get(opts, :refresher, GrantRefresher)

    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^id and active == true)
    |> Ash.Query.sort(created_at: :asc)
    |> Ash.read()
    |> case do
      {:ok, credentials} ->
        Enum.map(credentials, &entry(&1, account, now, refresher))

      {:error, error} ->
        Logger.warning("CredentialHealth: could not read credentials: #{inspect(error)}")
        []
    end
  end

  @doc """
  Every enabled, undeleted account of `provider` with its credential health,
  JSON-safe: `[%{account: "claude:default", health: "ok", credentials: [...]}]`.
  What `GET /api/server/claude_credentials` (`ward server doctor`) renders.
  """
  @spec report(atom(), keyword()) :: [map()]
  def report(provider, opts \\ []) when is_atom(provider) do
    ProviderAccount
    |> Ash.Query.filter(provider == ^provider and enabled == true and is_nil(deleted_at))
    |> Ash.Query.sort(slug: :asc)
    |> Ash.read()
    |> case do
      {:ok, accounts} -> Enum.map(accounts, &account_report(&1, opts))
      _ -> []
    end
  end

  defp account_report(%ProviderAccount{} = account, opts) do
    entries = for_account(account, opts)

    %{
      account: "#{account.provider}:#{account.slug}",
      health: entries |> summary() |> to_string(),
      credentials: Enum.map(entries, &to_map/1)
    }
  end

  @doc "The worst health among `entries` (`:none` for no entries)."
  @spec summary([%{health: health()}]) :: health() | :none
  def summary([]), do: :none

  def summary(entries),
    do: entries |> Enum.map(& &1.health) |> Enum.max_by(&Map.fetch!(@health_rank, &1))

  @doc "JSON-safe rendering of an entry (atoms to strings, datetimes to ISO 8601)."
  @spec to_map(entry()) :: map()
  def to_map(entry) do
    %{
      kind: to_string(entry.kind),
      health: to_string(entry.health),
      expiry: to_string(entry.expiry),
      expires_at: iso(entry.expires_at),
      access_expires_at: iso(entry.access_expires_at),
      detail: entry.detail,
      relogin: entry.relogin
    }
  end

  # -- entries -----------------------------------------------------------------

  defp entry(%ProviderCredential{kind: :oauth_token} = cred, account, now, _refresher) do
    expires_at = DateTime.add(cred.created_at, @setup_token_life_days * 86_400, :second)
    days_left = DateTime.diff(expires_at, now, :day)

    {health, detail} =
      cond do
        DateTime.compare(expires_at, now) != :gt ->
          {:expired, "the setup token is past its ~1 year life"}

        days_left <= @setup_token_warning_days ->
          {:expiring, "the setup token's ~1 year life ends in about #{days_left} day(s)"}

        true ->
          {:ok, "setup token, about #{days_left} day(s) of its ~1 year life left"}
      end

    base(
      :setup_token,
      health,
      :estimated,
      expires_at,
      nil,
      detail,
      setup_relogin(account, health)
    )
  end

  defp entry(%ProviderCredential{kind: :cli_credentials_path} = cred, _account, now, refresher) do
    case grant_path(cred) do
      {:ok, path} ->
        quota_grant(path, now, refresher)

      :error ->
        base(
          :quota_grant,
          :failing,
          :unknown,
          nil,
          nil,
          "the credential has no readable path",
          nil
        )
    end
  end

  defp entry(%ProviderCredential{kind: :cli_credentials_file}, _account, _now, _refresher),
    do: base(:stored_usage_token, :unknown, :unknown, nil, nil, "legacy stored usage token", nil)

  defp entry(%ProviderCredential{kind: :api_key}, _account, _now, _refresher),
    do: base(:api_key, :ok, :unknown, nil, nil, "API key (does not expire)", nil)

  defp entry(%ProviderCredential{kind: kind}, _account, _now, _refresher),
    do: base(kind, :unknown, :unknown, nil, nil, "#{kind} credential", nil)

  defp quota_grant(path, now, refresher) do
    login = "CLAUDE_CONFIG_DIR=#{GrantFile.config_dir(path)} claude auth login"
    refresh = refresher_status(refresher, path)

    case GrantFile.read(path) do
      {:error, reason} ->
        base(:quota_grant, :failing, :unknown, nil, nil, "grant unreadable: #{reason}", login)

      {:ok, %GrantFile{} = grant} ->
        {health, detail} = grant_health(grant, refresh, now)
        expiry = if grant.refresh_token_expires_at, do: :known, else: :unknown

        base(
          :quota_grant,
          health,
          expiry,
          grant.refresh_token_expires_at,
          grant.expires_at,
          detail,
          if(health == :ok, do: nil, else: login)
        )
    end
  end

  # First problem wins: the refresher failing, then the refresh token's life,
  # then an access token nothing is renewing.
  defp grant_health(grant, refresh, now) do
    with nil <- refresher_problem(refresh),
         nil <- refresh_token_problem(grant, now),
         nil <- access_token_problem(grant, refresh, now) do
      {:ok, "kept fresh by the quota grant refresher"}
    end
  end

  defp refresher_problem(:failing), do: {:failing, "the refresher could not renew the grant"}
  defp refresher_problem(_status), do: nil

  defp refresh_token_problem(%GrantFile{refresh_token_expires_at: %DateTime{} = at}, now) do
    case DateTime.diff(at, now, :millisecond) do
      ms when ms <= 0 ->
        {:expired, "the refresh token has expired; the CLI cannot renew the grant"}

      ms when ms <= @refresh_token_warning_ms ->
        {:expiring, "the refresh token expires within 2 days"}

      _ ->
        nil
    end
  end

  defp refresh_token_problem(_grant, _now), do: nil

  defp access_token_problem(%GrantFile{expires_at: %DateTime{} = at}, refresh, now) do
    if refresh != :ok and DateTime.compare(at, now) != :gt,
      do: {:expired, "the access token has lapsed and nothing renewed it"}
  end

  defp access_token_problem(_grant, _refresh, _now), do: nil

  defp setup_relogin(_account, :ok), do: nil

  defp setup_relogin(%ProviderAccount{provider: provider, slug: slug}, _health),
    do:
      "claude setup-token, then: arb account rotate #{provider}:#{slug} --kind oauth_token --secret <token>"

  defp base(kind, health, expiry, expires_at, access_expires_at, detail, relogin) do
    %{
      kind: kind,
      health: health,
      expiry: expiry,
      expires_at: expires_at,
      access_expires_at: access_expires_at,
      detail: detail,
      relogin: relogin
    }
  end

  # The credential's "secret" is a config dir (or its `.credentials.json`).
  defp grant_path(%ProviderCredential{} = cred) do
    case ProviderCredential.secret(cred) do
      location when is_binary(location) and location != "" ->
        expanded = Path.expand(location)

        {:ok,
         if(File.dir?(expanded), do: Path.join(expanded, ".credentials.json"), else: expanded)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # `:ok | :failing | :pending | nil` — what the running refresher thinks of
  # this grant; nil when there is no refresher.
  defp refresher_status(refresher, path) do
    case GrantRefresher.state(refresher) do
      %{grants: %{^path => %{status: status}}} -> status
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
