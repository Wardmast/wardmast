defmodule Wardmast.Test.CaptureNoSandbox do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Sandbox` this host does not have: `status/0` is an error, and
  anything that would run a command raises, so a test proves the capture never got that far.
  """

  @behaviour Wardmast.Screenshots.Capture.Sandbox

  @impl true
  def status, do: {:error, :not_on_this_host}

  @impl true
  def describe(:not_on_this_host), do: "this test host has no sandbox"

  @impl true
  def expose(_box, _port), do: raise("CaptureNoSandbox.expose/2 must never be called")

  @impl true
  def command(_argv, _box, _app), do: raise("CaptureNoSandbox.command/3 must never be called")

  @impl true
  def browser(_argv, _app, _writable),
    do: raise("CaptureNoSandbox.browser/3 must never be called")

  @impl true
  def browser(_argv, _app, _writable, _readonly),
    do: raise("CaptureNoSandbox.browser/4 must never be called")

  @impl true
  def reach(_app), do: raise("CaptureNoSandbox.reach/1 must never be called")

  @impl true
  def release(_app), do: :ok
end
