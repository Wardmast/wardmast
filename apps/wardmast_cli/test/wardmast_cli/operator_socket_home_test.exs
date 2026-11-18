defmodule WardmastCli.OperatorSocketHomeTest do
  # Mutates process env (ARB_HOME), so it cannot be async.
  use ExUnit.Case, async: false

  alias WardmastCli.OperatorSocket

  setup do
    saved = System.get_env("ARB_HOME")

    on_exit(fn ->
      if saved, do: System.put_env("ARB_HOME", saved), else: System.delete_env("ARB_HOME")
    end)
  end

  test "the client resolves the same run dir as the server for a configured home" do
    System.put_env("ARB_HOME", "/srv/other-home")
    Application.delete_env(:wardmast, :data_dir)
    assert OperatorSocket.run_dir() == "/srv/other-home/run"
    assert OperatorSocket.run_dir() == Wardmast.MCP.OperatorProof.run_dir()
  end

  test "defaults to ~/.wardmast/run without ARB_HOME" do
    System.delete_env("ARB_HOME")
    assert OperatorSocket.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
  end
end
