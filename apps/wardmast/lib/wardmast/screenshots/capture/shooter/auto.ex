defmodule Wardmast.Screenshots.Capture.Shooter.Auto do
  @moduledoc """
  The default `Wardmast.Screenshots.Capture.Shooter`: picks the cheaper one that can do the shot.

  The command-line `Shooter.Chromium` keeps every shot it can do (a route, a viewport, a colour
  scheme, a theme `query`); the CDP runner (`Shooter.Cdp`) takes any shot that needs a login,
  `steps`, `wait_for`, a `target`, `full_page`, `hide` or a theme `local_storage`. The test is
  `Shooter.Chromium.unsupported/1`, the same list that shooter refuses, so the two cannot drift
  apart: whatever one refuses, the other is asked.
  """

  @behaviour Wardmast.Screenshots.Capture.Shooter

  alias Wardmast.Screenshots.Capture.Shooter.Cdp
  alias Wardmast.Screenshots.Capture.Shooter.Chromium

  @impl true
  def shoot(spec), do: shooter_for(spec).shoot(spec)

  @doc "The shooter module that takes `spec`."
  @spec shooter_for(map()) :: module()
  def shooter_for(spec) do
    case Chromium.unsupported(spec) do
      [] -> Chromium
      _ -> Cdp
    end
  end
end
