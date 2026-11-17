defmodule Wardmast.Worker.PortableCpTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.PortableCp

  @gnu ["-a", "--reflink=auto", "src", "dst"]

  test "is the identity on Linux (GNU cp understands --reflink)" do
    assert PortableCp.args(@gnu, {:unix, :linux}) == @gnu

    assert PortableCp.args(["-a", "--reflink=always", "a", "b"], {:unix, :linux}) ==
             ["-a", "--reflink=always", "a", "b"]
  end

  test "on darwin, --reflink=always is a clonefile(2) copy (-c)" do
    assert PortableCp.args(["-a", "--reflink=always", "a", "b"], {:unix, :darwin}) ==
             ["-a", "-c", "a", "b"]
  end

  test "on darwin, --reflink=auto and --reflink=never are dropped for a plain cp -a" do
    assert PortableCp.args(@gnu, {:unix, :darwin}) == ["-a", "src", "dst"]

    assert PortableCp.args(["-a", "--reflink=never", "a", "b"], {:unix, :darwin}) == [
             "-a",
             "a",
             "b"
           ]
  end

  test "args/1 is a working cp argv on the host running the suite" do
    dir = Path.join(System.tmp_dir!(), "portable-cp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/f"), "x")
    on_exit(fn -> File.rm_rf(dir) end)

    argv = PortableCp.args(["-a", "--reflink=auto", Path.join(dir, "src"), Path.join(dir, "dst")])

    assert {_, 0} = System.cmd("cp", argv, stderr_to_stdout: true)
    assert File.read!(Path.join(dir, "dst/f")) == "x"
  end
end
