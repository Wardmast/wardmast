defmodule WardmastCli.DataHomeResolutionTest do
  # bd-88syir: the server and the `arb` escript resolve ONE data home
  # (`Wardmast.Env.data_home/0`). Every default that lives under it must follow
  # `WARDMAST_DATA_HOME`, whatever `HOME` says. Mutates the OS environment.
  use ExUnit.Case, async: false

  alias Wardmast.Config.Paths
  alias Wardmast.SingleInstance
  alias WardmastCli.Cmd.InstallService.Unit
  alias WardmastCli.Cmd.ReleaseDeploy.ReleaseFiles
  alias WardmastCli.OperatorSocket

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)

  @override_vars ~w(WARDMAST_DATA_HOME ARB_DATA_HOME ARBITER_DATA_HOME ARB_HOME WARDMAST_HOME
                    WARDMAST_ACCOUNTS_ROOT WARDMAST_PREVIEW_ROOT WARDMAST_IMAGE_ROOT
                    WARDMAST_MEMORY_ROOT WARDMAST_SERVER_LOG DATABASE_PATH SECRET_KEY_BASE)
  @config_keys [:accounts_root, :preview_root, :image_root, :memory_root, :server_log_path]

  setup do
    prior = Map.new(@override_vars, &{&1, System.get_env(&1)})
    prior_cfg = Map.new(@config_keys, &{&1, Application.fetch_env(:wardmast, &1)})
    prior_dir = Application.fetch_env(:wardmast, :data_dir)

    Enum.each(@override_vars, &System.delete_env/1)
    # runtime.exs refuses to evaluate without one (non-test env).
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    Enum.each(@config_keys, &Application.delete_env(:wardmast, &1))
    Application.delete_env(:wardmast, :data_dir)

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Enum.each(prior_cfg, fn
        {k, {:ok, v}} -> Application.put_env(:wardmast, k, v)
        {k, :error} -> Application.delete_env(:wardmast, k)
      end)

      case prior_dir do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end
    end)

    # Not the operator's real home: a path nothing here resolves to by accident.
    tmp = Path.join(System.tmp_dir!(), "data-home-#{System.unique_integer([:positive])}")
    {:ok, tmp: tmp}
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp runtime_db do
    @runtime
    |> Config.Reader.read!(env: :dev)
    |> Keyword.fetch!(:wardmast)
    |> Keyword.fetch!(Wardmast.Repo)
    |> Keyword.fetch!(:database)
  end

  test "WARDMAST_DATA_HOME moves every default; the user home does not", %{tmp: tmp} do
    refute under?(Path.join(System.user_home!(), ".wardmast"), tmp)
    System.put_env("WARDMAST_DATA_HOME", tmp)

    assert Paths.accounts_root() == Path.join(tmp, "accounts")
    assert Paths.preview_root() == Path.join(tmp, "previews")
    assert Paths.image_root() == Path.join(tmp, "images")
    assert Paths.memory_root() == Path.join(tmp, "memory")
    assert Paths.server_log_path() == Path.join([tmp, "log", "wardmast.log"])
    assert runtime_db() == Path.join(tmp, "arbiter.sqlite3")
    assert SingleInstance.lock_path() == Path.join(tmp, "wardmast.pid")
    assert ReleaseFiles.data_home() == tmp
    assert under?(ReleaseFiles.releases_dir(), tmp)
    assert OperatorSocket.run_dir() == Path.join(tmp, "run")
    assert Unit.arbiter_home_path() == tmp
    assert Wardmast.MCP.OperatorProof.run_dir() == Path.join(tmp, "run")
    assert Wardmast.Nodes.Agent.data_home() == tmp
  end

  test "the legacy ARB_DATA_HOME spelling moves them too (it used to move only the CLI)",
       %{tmp: tmp} do
    System.put_env("ARB_DATA_HOME", tmp)

    assert Paths.accounts_root() == Path.join(tmp, "accounts")
    assert ReleaseFiles.data_home() == tmp
    assert Unit.arbiter_home_path() == tmp
  end

  test "ARB_HOME and WARDMAST_HOME never move the data home", %{tmp: tmp} do
    System.put_env("ARB_HOME", tmp)
    System.put_env("WARDMAST_HOME", tmp)
    home = Path.join(System.user_home!(), ".wardmast")

    assert Paths.accounts_root() == Path.join(home, "accounts")
    assert Paths.server_log_path() == Path.join([home, "log", "wardmast.log"])
    assert ReleaseFiles.data_home() == home
    assert OperatorSocket.run_dir() == Path.join(home, "run")
  end

  test "explicit overrides still win over the data home", %{tmp: tmp} do
    System.put_env("WARDMAST_DATA_HOME", tmp)
    System.put_env("WARDMAST_ACCOUNTS_ROOT", "/explicit/accounts")
    System.put_env("WARDMAST_SERVER_LOG", "/explicit/server.log")
    System.put_env("DATABASE_PATH", "/explicit/db.sqlite3")

    assert Paths.accounts_root() == "/explicit/accounts"
    assert Paths.server_log_path() == "/explicit/server.log"
    assert runtime_db() == "/explicit/db.sqlite3"
  end

  test "the :bd2_arbiter_home test seam still wins for Unit.arbiter_home_path/0", %{tmp: tmp} do
    System.put_env("WARDMAST_DATA_HOME", tmp)
    Process.put(:bd2_arbiter_home, "/seam/home")
    on_exit(fn -> Process.delete(:bd2_arbiter_home) end)

    assert Unit.arbiter_home_path() == "/seam/home"
  end
end
