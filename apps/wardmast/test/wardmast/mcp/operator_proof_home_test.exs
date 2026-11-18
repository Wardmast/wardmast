defmodule Wardmast.MCP.OperatorProofHomeTest do
  # Mutates process env and app env, so it cannot be async.
  use ExUnit.Case, async: false

  alias Wardmast.MCP.OperatorProof

  @vars ["ARB_HOME", "WARDMAST_DATA_HOME", "ARB_DATA_HOME"]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    saved_app = Application.fetch_env(:wardmast, :data_dir)
    Enum.each(@vars, &System.delete_env/1)
    Application.delete_env(:wardmast, :data_dir)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      case saved_app do
        {:ok, v} -> Application.put_env(:wardmast, :data_dir, v)
        :error -> Application.delete_env(:wardmast, :data_dir)
      end
    end)
  end

  test "the fallback run dir lives under WARDMAST_DATA_HOME" do
    System.put_env("WARDMAST_DATA_HOME", "/srv/other-home")
    assert OperatorProof.run_dir() == "/srv/other-home/run"
  end

  test "the legacy ARB_DATA_HOME spelling is honoured" do
    System.put_env("ARB_DATA_HOME", "/srv/legacy-home")
    assert OperatorProof.run_dir() == "/srv/legacy-home/run"
  end

  test "ARB_HOME (the checkout) does not move the run dir" do
    System.put_env("ARB_HOME", "/srv/checkout")
    assert OperatorProof.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
  end

  test "an explicit :data_dir wins over WARDMAST_DATA_HOME" do
    System.put_env("WARDMAST_DATA_HOME", "/srv/other-home")
    Application.put_env(:wardmast, :data_dir, "/srv/data")
    assert OperatorProof.run_dir() == "/srv/data/run"
  end

  test "without any configured home it is ~/.wardmast/run" do
    assert OperatorProof.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
  end
end
