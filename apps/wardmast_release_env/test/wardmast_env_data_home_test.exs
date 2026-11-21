defmodule Wardmast.EnvDataHomeTest do
  # Mutates the OS environment (HOME, WARDMAST_DATA_HOME, ...) and the
  # `:wardmast` app env, both global.
  use ExUnit.Case, async: false

  alias Wardmast.Env

  @vars ~w(WARDMAST_DATA_HOME ARB_DATA_HOME ARBITER_DATA_HOME ARB_HOME WARDMAST_HOME)

  setup do
    prior = Map.new(@vars, &{&1, System.get_env(&1)})
    prior_cfg = Application.fetch_env(:wardmast, :data_dir)

    Enum.each(@vars, &System.delete_env/1)
    Application.delete_env(:wardmast, :data_dir)
    Env.reset_warnings()

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      case prior_cfg do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end

      Env.reset_warnings()
    end)
  end

  # `System.user_home/0` is fixed by the VM, not re-read from `$HOME` per call, so
  # assert against it rather than mutating HOME.
  defp default_home, do: Path.join(System.user_home!(), ".wardmast")

  describe "data_home/0 precedence" do
    test "defaults to ~/.wardmast under the user home" do
      assert Env.data_home() == default_home()
    end

    test "WARDMAST_DATA_HOME beats the HOME default" do
      System.put_env("WARDMAST_DATA_HOME", "/srv/ward")
      assert Env.data_home() == "/srv/ward"
    end

    test "legacy ARB_DATA_HOME is honoured through the shim" do
      System.put_env("ARB_DATA_HOME", "/srv/legacy")
      assert Env.data_home() == "/srv/legacy"
    end

    test "WARDMAST_DATA_HOME beats ARB_DATA_HOME" do
      System.put_env("WARDMAST_DATA_HOME", "/srv/new")
      System.put_env("ARB_DATA_HOME", "/srv/legacy")
      assert Env.data_home() == "/srv/new"
    end

    test "the :data_dir app env (test seam) beats the environment" do
      System.put_env("WARDMAST_DATA_HOME", "/srv/ward")
      Application.put_env(:wardmast, :data_dir, "/seam/dir")
      assert Env.data_home() == "/seam/dir"
    end
  end

  describe "data_home/0 empty values and expansion" do
    test "an empty WARDMAST_DATA_HOME falls through to the default" do
      System.put_env("WARDMAST_DATA_HOME", "")
      assert Env.data_home() == default_home()
    end

    test "an empty WARDMAST_DATA_HOME does not shadow ARB_DATA_HOME (as in env.sh)" do
      System.put_env("WARDMAST_DATA_HOME", "")
      System.put_env("ARB_DATA_HOME", "/srv/legacy")
      assert Env.data_home() == "/srv/legacy"
    end

    test "an empty :data_dir falls through to the environment" do
      System.put_env("WARDMAST_DATA_HOME", "/srv/ward")
      Application.put_env(:wardmast, :data_dir, "")
      assert Env.data_home() == "/srv/ward"
    end

    test "a non-binary :data_dir is ignored" do
      Application.put_env(:wardmast, :data_dir, nil)
      assert Env.data_home() == default_home()
    end

    test "~ in WARDMAST_DATA_HOME expands against HOME" do
      System.put_env("WARDMAST_DATA_HOME", "~/custom")
      assert Env.data_home() == Path.join(System.user_home!(), "custom")
    end

    test "~ in :data_dir expands against HOME" do
      Application.put_env(:wardmast, :data_dir, "~/seam")
      assert Env.data_home() == Path.join(System.user_home!(), "seam")
    end

    test "a relative value is expanded to an absolute path" do
      System.put_env("WARDMAST_DATA_HOME", "/srv/a/../b")
      assert Env.data_home() == "/srv/b"
    end
  end

  describe "data_home/0 ignores ambient variables" do
    test "ARB_HOME (the dev checkout) is ignored" do
      System.put_env("ARB_HOME", "/src/checkout")
      assert Env.data_home() == default_home()
    end

    test "WARDMAST_HOME is ignored" do
      System.put_env("WARDMAST_HOME", "/srv/ward-home")
      assert Env.data_home() == default_home()
    end
  end
end
