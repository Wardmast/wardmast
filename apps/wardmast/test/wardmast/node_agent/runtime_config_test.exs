defmodule Wardmast.NodeAgent.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` is gated on `WARDMAST_ROLE` (docs/design/remote-workers.md §3):
  an agent has no `SECRET_KEY_BASE`, no database and no cloak key, so none of
  the primary's runtime config (the `SECRET_KEY_BASE` raise, the Repo) may be
  evaluated for it. The default boot keeps its guard.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../../config/runtime.exs", __DIR__)
  @env_vars ~w(WARDMAST_ROLE SECRET_KEY_BASE DATABASE_PATH WARDMAST_CLOAK_KEY)

  setup do
    saved = for name <- @env_vars, do: {name, System.get_env(name)}
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  defp read(env), do: Config.Reader.read!(@runtime, env: env, target: :host)

  test "WARDMAST_ROLE=agent boots a prod config without SECRET_KEY_BASE, a DB path or the cloak key" do
    System.put_env("WARDMAST_ROLE", "agent")

    config = read(:prod)

    assert config[:wardmast][:role] == :agent
    refute Keyword.has_key?(config[:wardmast] || [], Wardmast.Repo)
    refute config[:wardmast_web][WardmastWeb.Endpoint][:secret_key_base]
    refute config[:wardmast_web][WardmastWeb.Endpoint][:server]
  end

  test "the deprecated ARB_ROLE still selects the agent role (one-release shim)" do
    Wardmast.Env.reset_warnings()
    System.put_env("ARB_ROLE", "agent")
    on_exit(fn -> System.delete_env("ARB_ROLE") end)

    config = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:config, read(:prod)}) end)
    assert_received {:config, config_kw}

    assert config_kw[:wardmast][:role] == :agent
    assert config =~ "ARB_ROLE is deprecated"
  end

  test "the same gate applies in dev, which also raises on a missing SECRET_KEY_BASE" do
    System.put_env("WARDMAST_ROLE", "agent")
    assert read(:dev)[:wardmast][:role] == :agent
  end

  test "the default (primary) prod boot still refuses to start without SECRET_KEY_BASE" do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn -> read(:prod) end
  end

  test "WARDMAST_ROLE=primary is the default boot, unchanged" do
    System.put_env("WARDMAST_ROLE", "primary")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))

    config = read(:prod)

    assert config[:wardmast][:role] == :primary
    assert config[:wardmast][Wardmast.Repo][:database]

    assert config[:wardmast_web][WardmastWeb.Endpoint][:secret_key_base] ==
             String.duplicate("k", 64)

    assert config[:wardmast_web][WardmastWeb.Endpoint][:server] == true
  end

  test "an unset WARDMAST_ROLE writes no role, so the application default (primary) applies" do
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    refute Keyword.has_key?(read(:prod)[:wardmast], :role)
  end

  test "an unknown WARDMAST_ROLE refuses to boot rather than falling back to primary" do
    System.put_env("WARDMAST_ROLE", "agnet")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    assert_raise RuntimeError, ~r/WARDMAST_ROLE/, fn -> read(:prod) end
  end
end
