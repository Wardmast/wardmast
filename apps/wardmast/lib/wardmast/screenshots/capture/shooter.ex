defmodule Wardmast.Screenshots.Capture.Shooter do
  @moduledoc """
  Takes one screenshot of one running route.

  `spec` is `%{role:, base_url:, path:, entry:, out_file:, config:, viewport:, theme:,
  timeout_s:, ctx:}`: `path` is the route for this role (`before_path` at the base), `entry` the
  `Wardmast.Screenshots.Plan` entry (steps, wait_for, target, ...), `viewport` / `theme` the
  resolved config maps. On success the shooter has written the image to `out_file`.

  A route that does not exist returns `{:error, {:http_status, 404}}`; the capture step reads that
  as "absent at this commit" (a new or removed route). Any other status is a route error. Anything
  else that goes wrong is `{:error, {:shot, detail}}`.
  """

  @callback shoot(map()) :: :ok | {:error, {:http_status, integer()} | {:shot, term()}}
end
