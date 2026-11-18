defmodule Wardmast.MCP.OperatorProofHomeTest do
  # Mutates process env (ARB_HOME) and app env, so it cannot be async.
  use ExUnit.Case, async: false

  alias Wardmast.MCP.OperatorProof

  setup do
    saved = {System.get_env("ARB_HOME"), Application.fetch_env(:wardmast, :data_dir)}
    Application.delete_env(:wardmast, :data_dir)

    on_exit(fn ->
      {home, data_dir} = saved
      if home, do: System.put_env("ARB_HOME", home), else: System.delete_env("ARB_HOME")

      case data_dir do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end
    end)
  end

  test "the fallback run dir lives under the configured ARB_HOME" do
    System.put_env("ARB_HOME", "/srv/other-home")
    assert OperatorProof.run_dir() == "/srv/other-home/run"
  end

  test "an explicit :data_dir wins over ARB_HOME" do
    System.put_env("ARB_HOME", "/srv/other-home")
    Application.put_env(:wardmast, :data_dir, "/srv/data")
    assert OperatorProof.run_dir() == "/srv/data/run"
  end

  test "without any configured home it is ~/.wardmast/run" do
    System.delete_env("ARB_HOME")
    assert OperatorProof.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
  end
end
