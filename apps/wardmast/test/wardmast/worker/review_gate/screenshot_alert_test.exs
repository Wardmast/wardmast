defmodule Wardmast.Worker.ReviewGate.ScreenshotAlertTest do
  use Wardmast.DataCase, async: true

  alias Wardmast.Alerts
  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Worker.ReviewGate.ScreenshotAlert

  @output """
  Compiling 628 files (.ex)
  Generated tonic app
  Running TonicWeb.Endpoint with Bandit failed, port 32790 already in use
  ** (Mix) Could not start application tonic: :eaddrinuse
  [info] shutting down
  """

  defp raise_with(failure) do
    state = %{task_id: "bd-x", repo: "tonic", workspace_id: nil}
    :ok = ScreenshotAlert.raise_failure(state, failure)
    [alert] = Alerts.active(kind: ScreenshotAlert.kind())
    alert
  end

  test "boot_failed subject names the last error line, not the first output line" do
    failure =
      Failure.new(:boot_failed, "the app failed to boot (boot): " <> @output,
        role: "after",
        detail: %{phase: :boot, output: @output}
      )

    alert = raise_with(failure)
    assert alert.subject =~ "(boot_failed)"
    assert alert.subject =~ "** (Mix) Could not start application tonic: :eaddrinuse"
    refute alert.subject =~ "Compiling"
  end

  test "boot_failed without any error line keeps the plain subject" do
    failure =
      Failure.new(:boot_failed, "boot",
        role: "after",
        detail: %{phase: :boot, output: "Compiling 1 file\nok"}
      )

    assert raise_with(failure).subject == "UI screenshot capture failing for tonic (boot_failed)"
  end
end
