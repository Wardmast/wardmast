defmodule Wardmast.Test.CaptureHostSandbox do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Sandbox` that isolates nothing: the app's commands and the
  browser run on the host exactly as given, and the app is reached over host loopback.

  It exists for tests about the boot itself (commands, the scrubbed environment, readiness,
  teardown, pairing), which must run on hosts with no bwrap. It is test support on purpose:
  production has no unsandboxed mode (`Capture` defaults to `Capture.Sandbox.Bwrap` and skips
  the capture when that is unavailable). The isolation is proven by
  `test/wardmast/screenshots/capture_sandbox_test.exs`, against a real bwrap.
  """

  @behaviour Wardmast.Screenshots.Capture.Sandbox

  @impl true
  def status, do: :ok

  @impl true
  def describe(reason), do: inspect(reason)

  @impl true
  def expose(_box, port), do: {:ok, %{port: port}}

  @impl true
  def command(argv, _box, _app), do: {:ok, argv}

  @impl true
  def browser(argv, _app, _writable), do: {:ok, argv}

  @impl true
  def browser(argv, _app, _writable, _readonly), do: {:ok, argv}

  @impl true
  def reach(_app), do: [connect_options: [timeout: 2_000]]

  @impl true
  def release(_app), do: :ok
end
