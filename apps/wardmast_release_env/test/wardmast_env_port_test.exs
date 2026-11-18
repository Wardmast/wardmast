defmodule Wardmast.EnvPortTest do
  # Mutates the OS environment, which is global.
  use ExUnit.Case, async: false

  alias Wardmast.Env

  @vars ~w(PORT WARDMAST_PORT ARB_PORT ARBITER_PORT)

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

  test "defaults to 4848" do
    assert Env.port() == 4848
    assert Env.server_port() == 4848
    assert Env.default_base_url() == "http://127.0.0.1:4848"
  end

  test "honours WARDMAST_PORT" do
    System.put_env("WARDMAST_PORT", "5151")
    assert Env.port() == 5151
    assert Env.server_port() == 5151
    assert Env.default_base_url() == "http://127.0.0.1:5151"
  end

  test "bare PORT only affects the server bind, never the client port" do
    System.put_env("PORT", "23456")
    assert Env.port() == 4848
    assert Env.server_port() == 23456
    System.put_env("WARDMAST_PORT", "5151")
    assert Env.server_port() == 5151
  end

  test "an unparseable port falls back to the default" do
    System.put_env("WARDMAST_PORT", "nope")
    assert Env.port() == 4848
    System.put_env("WARDMAST_PORT", "")
    assert Env.port() == 4848
  end
end
