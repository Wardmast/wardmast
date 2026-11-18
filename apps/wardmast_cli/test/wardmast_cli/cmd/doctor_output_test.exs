defmodule WardmastCli.Cmd.Doctor.OutputTest do
  use ExUnit.Case, async: true

  alias WardmastCli.Cmd.Doctor.{Checks, Formatter}
  alias WardmastCli.Cmd.Doctor.Checks.Result

  import ExUnit.CaptureIO

  test "restart hint is launchd on macOS and systemd elsewhere" do
    assert Checks.restart_hint({:unix, :darwin}) =~
             "launchctl kickstart gui/$(id -u)/com.wardmast.server"

    refute Checks.restart_hint({:unix, :darwin}) =~ "systemctl"
    assert Checks.restart_hint({:unix, :linux}) =~ "systemctl --user start arbiter"
  end

  test "text output is not HTML-escaped and uses the ward name" do
    results = [
      %Result{
        id: "a",
        group: :auth,
        name: "x",
        status: :warn,
        detail: "d",
        hint: "run `<data-home>/current/bin/wardmast start`"
      }
    ]

    out = capture_io(fn -> Formatter.emit_text(results) end)
    assert out =~ "auth & providers"
    assert out =~ "<data-home>/current/bin/wardmast start"
    refute out =~ "&amp;"
    refute out =~ "&lt;"
    assert out =~ "ward server doctor"
    refute out =~ "arb doctor"
  end
end
