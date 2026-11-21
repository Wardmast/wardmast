defmodule Wardmast.Test.SessionEnv do
  @moduledoc """
  Point the session roots at throwaway tmp dirs for one test (bd-aprlbb).

  Exists because the obvious spelling is wrong in a way that only shows up in
  *another* test file: `Application.put_env/3` in `setup` plus
  `Application.delete_env/2` in `on_exit` does not restore the value
  `config/test.exs` set — it **deletes** it, so every later test in the same VM
  falls through to the `$HOME`-relative default and provisions a session into
  the operator's real `~/dev/arbiter-sessions`. Save-and-restore, always.
  """

  @keys [
    :sessions_root,
    :accounts_root,
    :sessions_runtime_dir,
    :primary_checkout,
    :sessions_credentials_source,
    :sessions_agy_source_home,
    :sessions_agent_command,
    :sessions_launch_command,
    :sessions_bridge_verify_timeout_ms,
    :sessions_bridge_verify_poll_interval_ms,
    :memory_root
  ]

  @doc """
  Override the given `:wardmast` keys for this test, restoring the previous
  values (including "was unset") on exit. Returns the overrides, so a `setup`
  block can hand them straight to the test context.
  """
  @spec override(keyword()) :: keyword()
  def override(overrides) do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:wardmast, &1)})

    Enum.each(overrides, fn {key, value} ->
      true = key in @keys
      Application.put_env(:wardmast, key, value)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:wardmast, key, value)
        {key, :error} -> Application.delete_env(:wardmast, key)
      end)
    end)

    overrides
  end

  @doc """
  A full set of unique tmp roots for a session test — `:sessions_root`,
  `:sessions_runtime_dir`, `:primary_checkout`, `:sessions_credentials_source`
  and `:sessions_agy_source_home` — all removed on exit.
  """
  @spec sandbox(String.t()) :: keyword()
  def sandbox(tag) do
    unique = "#{tag}-#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "arbiter-session-test-#{unique}")

    runtime = runtime_dir(base)

    overrides = [
      sessions_root: Path.join(base, "sessions"),
      sessions_runtime_dir: runtime,
      accounts_root: Path.join(base, "accounts"),
      primary_checkout: Path.join(base, "checkout"),
      sessions_credentials_source: Path.join(base, "operator"),
      sessions_agy_source_home: Path.join(base, "operator-home"),
      memory_root: Path.join(base, "memory")
    ]

    File.mkdir_p!(overrides[:primary_checkout])
    File.mkdir_p!(overrides[:sessions_credentials_source])
    File.mkdir_p!(overrides[:sessions_agy_source_home])

    ExUnit.Callbacks.on_exit(fn ->
      Wardmast.Worker.RunTmp.force_rm_rf(base)
      if runtime != Path.join(base, "runtime"), do: Wardmast.Worker.RunTmp.force_rm_rf(runtime)
    end)

    override(overrides)
  end

  # On darwin `$TMPDIR` is a long `/var/folders/...` path, so a socket under it
  # overflows the 103-byte limit (bd-15labm). Use a short `/tmp` dir there.
  defp runtime_dir(base), do: short_runtime_dir(Path.join(base, "runtime"))

  @doc """
  A `:sessions_runtime_dir` value that keeps `<dir>/arbiter/session-<uuid>.sock`
  under the 103-byte Unix-socket limit (bd-15labm).

  On darwin it is a fresh `/tmp/arb-s-N` directory (created, removed on exit);
  elsewhere it is `fallback`, returned untouched, so Linux placement is unchanged.
  """
  @spec short_runtime_dir(Path.t()) :: Path.t()
  def short_runtime_dir(fallback) do
    darwin? =
      Application.get_env(:wardmast, :sessions_os) == :darwin or
        match?({:unix, :darwin}, :os.type())

    if darwin? do
      dir = Path.join("/tmp", "arb-s-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      ExUnit.Callbacks.on_exit(fn -> Wardmast.Worker.RunTmp.force_rm_rf(dir) end)
      dir
    else
      fallback
    end
  end

  @doc """
  Sandbox the session roots and launch one stubbed session, returning the row.

  For tests outside `apps/wardmast` that need a real session row (and therefore
  a real revocation handle) without caring how it got there.
  """
  @spec launch_session!(keyword()) :: struct()
  def launch_session!(opts \\ []) do
    sandbox("launched")

    {:ok, session} =
      Wardmast.Sessions.launch(Keyword.put_new(opts, :runner, Wardmast.Test.SessionRunnerStub))

    session
  end

  @doc """
  Give the launch form something to offer (bd-8qoxst): it lists a session
  provider only when a live provider account exists for it, and — once a
  workspace is picked — only when that workspace is joined to the account.
  Creates `claude:default` and `antigravity:default` and joins each of
  `workspaces` to both. Idempotent; call it from a `setup` that owns the
  sandbox.
  """
  @spec launch_accounts!([struct()]) :: :ok
  def launch_accounts!(workspaces \\ []) do
    accounts =
      for provider <- [:claude, :antigravity] do
        account =
          Wardmast.Accounts.get_account("#{provider}:default")
          |> case do
            {:ok, account} ->
              account

            _ ->
              Ash.create!(Wardmast.Accounts.ProviderAccount, %{
                provider: provider,
                slug: "default"
              })
          end

        {provider, account}
      end

    # A connected claude account has a setup token; the launch form's account
    # picker launches with it (bd-6y4pj6).
    {:claude, claude_default} = List.keyfind(accounts, :claude, 0)

    if Wardmast.Accounts.Credentials.account_setup_token(claude_default.id) == :none,
      do: connect_claude_setup_token!(claude_default)

    for workspace <- workspaces, {provider, account} <- accounts do
      {:ok, _} = Wardmast.Accounts.attach_workspace(workspace.id, provider, account.id)
    end

    :ok
  end

  @doc """
  Give a Claude account its `claude setup-token` secret (an `:oauth_token`
  credential) — what a session launched for that account authenticates with
  (bd-6y4pj6). Without it the launch is refused with the "run `claude
  setup-token`" message, which is the point of the guard; a test that is not
  about that wants the account connected.
  """
  @spec connect_claude_setup_token!(Wardmast.Accounts.ProviderAccount.t(), String.t() | nil) ::
          String.t()
  def connect_claude_setup_token!(account, token \\ nil) do
    token = token || "sk-ant-oat01-TEST-SETUP-#{account.slug}"

    Ash.create!(Wardmast.Accounts.ProviderCredential, %{
      provider_account_id: account.id,
      kind: :oauth_token,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-#{System.unique_integer([:positive])}",
      secret: token
    })

    token
  end
end
