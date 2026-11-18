defmodule WardmastCli.Scripts.WardWrapperTest do
  @moduledoc """
  bd-d5mg29: `rel/overlays/bin/ward` runs the ward escript on the release's
  bundled erts with no system Erlang. A stub `escript` in a fake release's
  `erts-*/bin` records what the wrapper put in its environment.
  """
  use ExUnit.Case, async: true

  @wrapper Path.expand("../../../../rel/overlays/bin/ward", __DIR__)
  @moduletag :tmp_dir

  defp fake_release!(dir) do
    root = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "erts-99.0/bin"))
    File.mkdir_p!(Path.join(root, "releases/1.2.3"))
    File.cp!(@wrapper, Path.join(root, "bin/ward"))
    File.chmod!(Path.join(root, "bin/ward"), 0o755)
    File.write!(Path.join(root, "releases/1.2.3/start_clean.boot"), "BOOT")
    File.write!(Path.join(root, "releases/start_erl.data"), "99.0 1.2.3\n")
    File.write!(Path.join(root, "bin/ward.escript"), "ESCRIPT")

    stub = Path.join(root, "erts-99.0/bin/escript")

    File.write!(stub, """
    #!/bin/sh
    echo "ERL_FLAGS=$ERL_FLAGS"
    echo "PATH0=${PATH%%:*}"
    echo "ARGS=$*"
    """)

    File.chmod!(stub, 0o755)
    root
  end

  defp run(root, args, env \\ []) do
    System.cmd(Path.join(root, "bin/ward"), args,
      env: [{"ERL_FLAGS", nil}] ++ env,
      stderr_to_stdout: true
    )
  end

  test "sets RELEASE_LIB boot var, puts release erts first, runs the sibling escript",
       %{tmp_dir: dir} do
    root = fake_release!(dir)
    {out, 0} = run(root, ["--version"])
    {:ok, real} = {:ok, Path.join(Path.expand(root), "")}
    assert out =~ "-boot_var RELEASE_LIB #{real}/lib"
    assert out =~ "PATH0=#{real}/erts-99.0/bin"
    assert out =~ "ARGS=#{real}/bin/ward.escript --version"
  end

  test "creates bin/no_dot_erlang.boot from start_clean.boot when missing", %{tmp_dir: dir} do
    root = fake_release!(dir)
    {_, 0} = run(root, ["--version"])
    assert File.read!(Path.join(root, "bin/no_dot_erlang.boot")) == "BOOT"
  end

  test "WARD_ESCRIPT overrides the escript and existing ERL_FLAGS are kept", %{tmp_dir: dir} do
    root = fake_release!(dir)
    other = Path.join(dir, "other.escript")
    File.write!(other, "X")
    {out, 0} = run(root, ["x"], [{"WARD_ESCRIPT", other}, {"ERL_FLAGS", "+fnu"}])
    assert out =~ "ERL_FLAGS=+fnu -boot_var RELEASE_LIB"
    assert out =~ "ARGS=#{other} x"
  end

  test "fails clearly when no escript is found", %{tmp_dir: dir} do
    root = fake_release!(dir)
    File.rm!(Path.join(root, "bin/ward.escript"))
    {out, status} = run(root, [])
    assert status != 0
    assert out =~ "WARD_ESCRIPT"
  end
end
