defmodule WardmastCli.Cmd.Doctor.CaptureRunnerTest do
  use ExUnit.Case, async: true

  alias WardmastCli.Cmd.Doctor.CaptureRunner

  test "no row when screenshots are not enabled or the server is older" do
    assert CaptureRunner.checks(%{"enabled" => false, "problems" => []}) == []
    assert CaptureRunner.checks(nil) == []
  end

  test "ready runner is ok" do
    [r] =
      CaptureRunner.checks(%{
        "enabled" => true,
        "node" => "v22.1.0",
        "playwright_core" => "1.65.1",
        "chromium" => "/usr/bin/chromium",
        "problems" => []
      })

    assert r.status == :ok
    assert r.detail =~ "1.65.1"
  end

  test "problems warn with a hint" do
    [r] =
      CaptureRunner.checks(%{
        "enabled" => true,
        "dir" => "/x/priv/capture",
        "problems" => ["playwright-core is not installed"]
      })

    assert r.status == :warn
    assert r.detail =~ "playwright-core"
    assert r.hint =~ "/x/priv/capture"
  end
end
