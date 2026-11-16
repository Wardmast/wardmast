defmodule WardmastWeb.Boot.BindAddressCheckTest do
  @moduledoc """
  bd-1c4pg3: the dashboard's auth model is "a loopback peer is trusted;
  there is no login" (see `WardmastWeb.Loopback`). Binding off-loopback is now
  an explicit, opt-in choice (`WARDMAST_BIND_ADDRESS`) rather than the default, but
  it must still be loud about the exposure at boot.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WardmastWeb.Boot.BindAddressCheck

  test "logs no warning for a loopback bind" do
    log = capture_log(fn -> BindAddressCheck.warn_if_off_loopback({127, 0, 0, 1}) end)
    assert log == ""
  end

  test "logs no warning for the IPv6 loopback bind" do
    log = capture_log(fn -> BindAddressCheck.warn_if_off_loopback({0, 0, 0, 0, 0, 0, 0, 1}) end)
    assert log == ""
  end

  test "logs a clear warning for a non-loopback bind" do
    log =
      capture_log(fn -> BindAddressCheck.warn_if_off_loopback({0, 0, 0, 0}) end)

    assert log =~ "WARNING"
    assert log =~ "no login"
    assert log =~ "WARDMAST_BIND_ADDRESS"
  end

  test "logs a clear warning for a non-loopback dual-stack bind" do
    log = capture_log(fn -> BindAddressCheck.warn_if_off_loopback({0, 0, 0, 0, 0, 0, 0, 0}) end)

    assert log =~ "WARNING"
    assert log =~ "no login"
  end
end
