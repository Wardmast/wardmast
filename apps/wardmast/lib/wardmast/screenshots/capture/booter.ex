defmodule Wardmast.Screenshots.Capture.Booter do
  @moduledoc """
  Boots the app from one source tree so the capture step can shoot it, and stops it again.

  `spec` is `%{role:, checkout:, scratch:, seed:, config:, task_id:, sandbox:, ctx:}`: `role` is
  `"before"` or `"after"`, `checkout` the extracted source tree, `scratch` a per-boot directory
  for databases and logs, `seed` a named seed from the config (or `nil`), `config` the resolved
  `Wardmast.Screenshots.Config`, `sandbox` the `Wardmast.Screenshots.Capture.Sandbox` every
  command must run in (a booter that runs anything must refuse without one). `ctx` is the opaque
  `:ctx` option of `Capture.run/2`.

  `boot/1` returns the base URL the app answers on, a handle for `stop/2` and, when the app runs
  in a sandbox, `app` (the sandbox's `expose/2` result, which the shooter needs to reach it), or
  `{:error, {phase, detail}}` where `phase` is `:setup`, `:seed`, `:start` or `:ready`.
  `stop/2` must always leave nothing running; the capture step calls it even when a shot failed.
  """

  @type spec :: map()
  @type phase :: :setup | :seed | :start | :ready

  @callback boot(spec()) ::
              {:ok,
               %{
                 required(:handle) => term(),
                 required(:base_url) => String.t(),
                 optional(:app) => map()
               }}
              | {:error, {phase(), term()}}
  @callback stop(spec(), handle :: term()) :: :ok
end
