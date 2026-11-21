defmodule Wardmast.Accounts.CodexLoginCredentialFlowTest do
  @moduledoc """
  bd-2cua01: `arb account login codex:default` has to write the credential the
  usage poll and newly spawned Codex workers actually read. The login now runs
  against the Codex source home (`Wardmast.Agents.Codex.ConfigDir.source_home/0`),
  so the poll (which reads `<source home>/auth.json`) and a worker's per-worktree
  `CODEX_HOME` (whose `auth.json` links to it) both see the new token.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts
  alias Wardmast.Accounts.LoginCompletion
  alias Wardmast.Accounts.LoginRecipes
  alias Wardmast.Accounts.ProviderCredential
  alias Wardmast.Agents.Codex.ConfigDir
  alias Wardmast.Quota.Codex

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    source = Path.join(tmp, "source-codex")
    root = Path.join(tmp, "worker-codex")
    worktree = Path.join(tmp, "wt/feature-1")
    File.mkdir_p!(source)
    File.mkdir_p!(worktree)

    keys = [:worker_isolate_config, :worker_codex_home_root, :worker_codex_source_home]
    prev = Map.new(keys, &{&1, Application.get_env(:wardmast, &1)})
    prev_quota = Application.get_env(:wardmast, :codex_quota)

    Application.put_env(:wardmast, :worker_isolate_config, true)
    Application.put_env(:wardmast, :worker_codex_home_root, root)
    Application.put_env(:wardmast, :worker_codex_source_home, source)
    # The test config pins the poll at a nonexistent file; clear it so the
    # poll resolves its path the way production does.
    Application.put_env(:wardmast, :codex_quota, [])

    on_exit(fn ->
      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:wardmast, key)
        {key, val} -> Application.put_env(:wardmast, key, val)
      end)

      case prev_quota do
        nil -> Application.delete_env(:wardmast, :codex_quota)
        v -> Application.put_env(:wardmast, :codex_quota, v)
      end
    end)

    {:ok, source: source, worktree: worktree}
  end

  # What `codex login --device-auth` does: writes auth.json into the dir the
  # login runner hands it as CODEX_HOME.
  defp simulate_codex_login(slug, token) do
    dir = LoginRecipes.config_dir(:codex, slug)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "auth.json"),
      Jason.encode!(%{"tokens" => %{"access_token" => token, "account_id" => "acct-1"}})
    )

    dir
  end

  defp complete(slug, dir) do
    LoginCompletion.complete(%{provider: :codex, account: slug, config_dir: dir},
      outcome: :succeeded
    )
  end

  test "login then poll: the usage poll reads the auth.json the login wrote" do
    dir = simulate_codex_login("default", "NEW-TOKEN")
    assert {:ok, %{credential: :referenced}} = complete("default", dir)

    assert {:ok, %{access_token: "NEW-TOKEN", account_id: "acct-1"}} = Codex.read_credentials([])
  end

  test "login then spawn: a worker's config dir links to the auth.json the login wrote",
       %{worktree: worktree} do
    dir = simulate_codex_login("default", "NEW-TOKEN")
    assert {:ok, _} = complete("default", dir)

    assert {:ok, home} = ConfigDir.ensure(worktree_path: worktree)
    assert {:ok, target} = File.read_link(Path.join(home, "auth.json"))
    assert Path.expand(target, home) == Path.join(dir, "auth.json")

    assert Jason.decode!(File.read!(Path.join(home, "auth.json")))["tokens"]["access_token"] ==
             "NEW-TOKEN"
  end

  test "login completion records the credential reference at that file" do
    dir = simulate_codex_login("default", "NEW-TOKEN")
    assert {:ok, _} = complete("default", dir)

    {:ok, account} = Accounts.get_account("codex:default")

    assert [credential] =
             ProviderCredential
             |> Ash.read!()
             |> Enum.filter(&(&1.provider_account_id == account.id and &1.active))
             |> Ash.load!(:secret)

    assert credential.kind == :cli_credentials_path
    assert credential.secret == Path.join(dir, "auth.json")
  end
end
