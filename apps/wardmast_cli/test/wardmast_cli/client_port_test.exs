defmodule WardmastCli.ClientPortTest do
  # Mutates the OS environment, which is global.
  use ExUnit.Case, async: false

  alias WardmastCli.Client

  @vars ~w(PORT WARDMAST_HOST ARB_HOST ARBITER_HOST)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "base_url defaults to 4848" do
    assert Client.base_url() == "http://127.0.0.1:4848"
  end

  test "base_url honours a non-default PORT" do
    System.put_env("PORT", "5151")
    assert Client.base_url() == "http://127.0.0.1:5151"
  end

  test "an explicit WARDMAST_HOST wins over PORT" do
    System.put_env("PORT", "5151")
    System.put_env("WARDMAST_HOST", "http://10.0.0.1:9000")
    assert Client.base_url() == "http://10.0.0.1:9000"
  end
end
