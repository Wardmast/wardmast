defmodule Wardmast.Test.CaptureRecordingSandbox do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Sandbox` for tests about how a shooter uses the sandbox: it
  sends the calling process what `browser/3,4` was asked for and wraps the argv in a marker
  (`wrapped-by-sandbox`, run by `sh`), so a test can tell a shooter that goes through the sandbox
  from one that runs its program directly. The wrapper runs the argv as given; it isolates nothing.
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
  def browser(argv, app, writable), do: browser(argv, app, writable, [])

  @impl true
  def browser(_argv, %{fail: true}, _writable, _readonly), do: {:error, :boom}

  def browser(argv, app, writable, readonly) do
    send(self(), {:sandbox_browser, argv, app, writable, readonly})
    {:ok, ["/bin/sh", "-c", ~s(exec "$@"), "wrapped-by-sandbox" | argv]}
  end

  @impl true
  def reach(_app), do: []

  @impl true
  def release(_app), do: :ok
end
