defmodule WardmastCli.OperatorSocketHomeTest do
  # Mutates process env, so it cannot be async.
  use ExUnit.Case, async: false

  alias WardmastCli.OperatorSocket

  @vars ["ARB_HOME", "WARDMAST_DATA_HOME", "ARB_DATA_HOME", "ARB_OPERATOR_SOCKET"]

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

  test "client and server agree on <data_home>/run with only WARDMAST_DATA_HOME set" do
    System.put_env("WARDMAST_DATA_HOME", "/srv/other-home")
    assert OperatorSocket.run_dir() == "/srv/other-home/run"
    assert OperatorSocket.run_dir() == Wardmast.MCP.OperatorProof.run_dir()
  end

  test "ARB_HOME (the checkout) does not move the run dir" do
    System.put_env("ARB_HOME", "/srv/checkout")
    assert OperatorSocket.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
    assert OperatorSocket.run_dir() == Wardmast.MCP.OperatorProof.run_dir()
  end

  test "defaults to ~/.wardmast/run" do
    assert OperatorSocket.run_dir() == Path.join(Path.expand("~/.wardmast"), "run")
  end

  test "socket_path/0 matches OperatorProof.socket_path/1 when /run/user is absent" do
    System.put_env("WARDMAST_DATA_HOME", "/srv/other-home")
    port = URI.parse(WardmastCli.Client.base_url()).port || Wardmast.Env.port()

    if File.dir?("/run/user") do
      # Per-user runtime dir exists on this host: both sides take that branch.
      assert Path.dirname(OperatorSocket.socket_path()) ==
               Path.dirname(Wardmast.MCP.OperatorProof.socket_path(port))
    else
      assert OperatorSocket.socket_path() == Wardmast.MCP.OperatorProof.socket_path(port)
      assert OperatorSocket.socket_path() == "/srv/other-home/run/operator-#{port}.sock"
    end
  end
end
