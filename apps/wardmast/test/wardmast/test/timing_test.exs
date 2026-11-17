defmodule Wardmast.Test.TimingTest do
  # Mutates the :ex_unit application env (restored in on_exit).
  use ExUnit.Case, async: false

  alias Wardmast.Test.Timing

  setup do
    old = Application.fetch_env!(:ex_unit, :assert_receive_timeout)
    on_exit(fn -> Application.put_env(:ex_unit, :assert_receive_timeout, old) end)
  end

  test "is the identity at ExUnit's 100 ms default" do
    Application.put_env(:ex_unit, :assert_receive_timeout, 100)
    assert Timing.scale(1_000) == 1_000
  end

  test "scales with a raised assert_receive_timeout (the macOS host tuning)" do
    Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
    assert Timing.scale(1_000) == 10_000
  end

  test "never shrinks a budget" do
    Application.put_env(:ex_unit, :assert_receive_timeout, 10)
    assert Timing.scale(500) == 500
  end

  test "await/2 returns true as soon as the condition holds, false once the budget is spent" do
    assert Timing.await(fn -> true end, 50)
    refute Timing.await(fn -> false end, 30)
  end
end
