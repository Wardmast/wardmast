defmodule Wardmast.EnvPortTest do
  # Mutates the OS environment, which is global.
  use ExUnit.Case, async: false

  alias Wardmast.Env

  setup do
    prev = System.get_env("PORT")

    on_exit(fn ->
      if prev, do: System.put_env("PORT", prev), else: System.delete_env("PORT")
    end)

    System.delete_env("PORT")
    :ok
  end

  test "defaults to 4848" do
    assert Env.port() == 4848
    assert Env.default_base_url() == "http://127.0.0.1:4848"
  end

  test "honours PORT" do
    System.put_env("PORT", "5151")
    assert Env.port() == 5151
    assert Env.default_base_url() == "http://127.0.0.1:5151"
  end

  test "an unparseable PORT falls back to the default" do
    System.put_env("PORT", "nope")
    assert Env.port() == 4848
    System.put_env("PORT", "")
    assert Env.port() == 4848
  end
end
