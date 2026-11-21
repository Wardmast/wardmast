defmodule Wardmast.Screenshots.Capture.Shooter do
  @moduledoc """
  Takes one screenshot of one running route.

  `spec` is `%{role:, base_url:, path:, entry:, out_file:, config:, viewport:, theme:,
  timeout_s:, sandbox:, app:, scratch:, ctx:}`: `path` is the route for this role (`before_path` at
  the base), `entry` the `Wardmast.Screenshots.Plan` entry (steps, wait_for, target, ...),
  `viewport` / `theme` the resolved config maps. `sandbox` is the capture's
  `Wardmast.Screenshots.Capture.Sandbox` and `app` the booter's handle on the app inside it: a
  shooter that starts a browser runs it through `sandbox.browser/3` and reaches the app with
  `sandbox.reach/1`, or refuses. `scratch` is a fresh directory for this shot alone (the only
  place a browser should write). On success the shooter has written the image to `out_file` and returns
  `{:ok, %{text: [String.t()]}}`: the page's visible text and its `alt`/`title` values, which the
  capture step scans for data that must not leave (`Capture.Safety`, bd-995svb). A bare `:ok`
  reports no text, so the shot is withheld (`scan-unavailable`): an unscanned page is never trusted.

  A route that does not exist returns `{:error, {:http_status, 404}}`; the capture step reads that
  as "absent at this commit" (a new or removed route). Any other status is a route error. Anything
  else that goes wrong is `{:error, {:shot, detail}}`.
  """

  @callback shoot(map()) ::
              :ok
              | {:ok, %{required(:text) => [String.t()]}}
              | {:error, {:http_status, integer()} | {:shot, term()}}
end
