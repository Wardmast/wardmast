defmodule Wardmast.Screenshots.Capture.Booter.CommandReadyTest do
  # bd-b2e1ev: the readiness re-check and the log tail a booted app hands the capture step.
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Booter.Command
  alias Wardmast.Test.CaptureHostSandbox

  defp handle(script, url) do
    {:ok, process} =
      AppProcess.start_link(%{
        argv: [System.find_executable("sh"), "-c", script],
        cd: System.tmp_dir!(),
        env: []
      })

    on_exit(fn -> AppProcess.stop(process) end)

    %{
      process: process,
      sandbox: CaptureHostSandbox,
      exposed: %{port: 1},
      ready_url: url,
      expect: "below_500"
    }
  end

  test "an app whose process exited is not ready, and its output is the log tail" do
    h = handle("echo crashed-on-purpose; exit 4", "http://127.0.0.1:1/")
    {:exited, 4, _} = AppProcess.await_exit(h.process, 5_000)

    assert {:error, msg} = Command.ready(%{}, h)
    assert msg =~ "status 4"
    assert Command.log_tail(%{}, h) =~ "crashed-on-purpose"
  end

  test "a running app that refuses connections is not ready" do
    h = handle("echo up; sleep 30", "http://127.0.0.1:1/")
    assert {:error, msg} = Command.ready(%{}, h)
    assert msg =~ "GET http://127.0.0.1:1/"
  end

  test "a running app that answers is ready" do
    bandit =
      start_supervised!({Bandit, plug: Wardmast.Test.CdpFixtureApp, port: 0, ip: :loopback})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    h = handle("sleep 30", "http://127.0.0.1:#{port}/login")
    assert :ok = Command.ready(%{}, h)
  end
end
