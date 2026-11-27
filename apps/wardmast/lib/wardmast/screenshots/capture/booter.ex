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
  @doc """
  Optional. Probe the booted app again, right before a side's first navigation: `:ok` or
  `{:error, detail}` when it no longer answers (it crashed, or it was never really up).
  """
  @callback ready(spec(), handle :: term()) :: :ok | {:error, term()}

  @doc "Optional. The tail of the app's own server output, for a failure report."
  @callback log_tail(spec(), handle :: term()) :: String.t() | nil

  @doc """
  Optional (bd-b2e1ev). After a transport failure (the browser got an empty or reset response):
  the host's own GET of `path` straight to the app, described in one line, to tell "the app
  never answers that path" from "only the browser's route to it fails".
  """
  @callback diagnose(spec(), handle :: term(), path :: String.t()) :: String.t() | nil

  @callback stop(spec(), handle :: term()) :: :ok
  @optional_callbacks ready: 2, log_tail: 2, diagnose: 3
end
