defmodule WardmastCli.Cmd.InstallService.DataHomeTest do
  # async: false — mutates env vars and the :wardmast app env.
  use ExUnit.Case, async: false

  alias WardmastCli.Cmd.InstallService.DataHome

  setup do
    names = ~w(ARB_HOME WARDMAST_DATA_HOME ARB_DATA_HOME)
    saved = for k <- names, do: {k, System.get_env(k)}
    prior_dir = Application.fetch_env(:wardmast, :data_dir)
    for k <- names, do: System.delete_env(k)
    Process.delete(:bd2_arbiter_home)

    tmp = Path.join(System.tmp_dir!(), "arb-dh-unit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))

      case prior_dir do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp release_bin!(home) do
    bin = Path.join([home, "current", "bin", "wardmast"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\n")
  end

  describe "resolve_release/1" do
    test "defaults to Wardmast.Env.data_home/0 (<HOME>/.wardmast), source :default", %{tmp: tmp} do
      # `System.user_home!/0` is fixed at VM boot, so `HOME=<dir>` is pinned
      # here through the seam `Wardmast.Env.data_home/0` consults first.
      scratch = Path.join(tmp, "scratch-home/.wardmast")
      Application.put_env(:wardmast, :data_dir, scratch)

      assert DataHome.resolve_release(tmp) == %{path: scratch, source: :default}
    end

    test "ARB_HOME with a nested release derives <ARB_HOME>/.wardmast", %{tmp: tmp} do
      release_bin!(Path.join(tmp, ".wardmast"))
      System.put_env("ARB_HOME", tmp)

      assert DataHome.resolve_release(tmp) ==
               %{path: Path.join(tmp, ".wardmast"), source: :arb_home_release}
    end

    test "ARB_HOME that holds current/ itself is the data home", %{tmp: tmp} do
      release_bin!(tmp)
      System.put_env("ARB_HOME", tmp)

      assert DataHome.resolve_release(tmp) == %{path: tmp, source: :arb_home_release}
    end

    test "ARB_HOME with no release yet falls back to <ARB_HOME>/.wardmast", %{tmp: tmp} do
      System.put_env("ARB_HOME", tmp)

      assert DataHome.resolve_release(tmp).path == Path.join(tmp, ".wardmast")
    end

    test "an explicit WARDMAST_DATA_HOME beats ARB_HOME", %{tmp: tmp} do
      release_bin!(Path.join(tmp, ".wardmast"))
      System.put_env("ARB_HOME", tmp)
      System.put_env("WARDMAST_DATA_HOME", "/srv/explicit")

      assert DataHome.resolve_release(tmp) == %{path: "/srv/explicit", source: :explicit_env}
    end

    test "legacy ARB_DATA_HOME counts as explicit; empty values do not", %{tmp: tmp} do
      System.put_env("ARB_DATA_HOME", "/srv/legacy")
      System.put_env("WARDMAST_DATA_HOME", "")
      assert DataHome.resolve_release(tmp).source == :explicit_env
      assert DataHome.explicit() == "/srv/legacy"

      System.delete_env("ARB_DATA_HOME")
      assert DataHome.explicit() == nil
    end
  end

  describe "resolve/1 (dev checkout)" do
    test "never derives from ARB_HOME; exports only an explicit value", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "apps"))
      File.write!(Path.join(tmp, "mix.exs"), "# checkout\n")
      System.put_env("ARB_HOME", tmp)
      Application.put_env(:wardmast, :data_dir, Path.join(tmp, "default-data"))

      assert DataHome.resolve(tmp) ==
               %{path: Path.join(tmp, "default-data"), source: :default}

      System.put_env("WARDMAST_DATA_HOME", "/srv/explicit")
      assert DataHome.resolve(tmp) == %{path: "/srv/explicit", source: :explicit_env}
    end
  end
end
