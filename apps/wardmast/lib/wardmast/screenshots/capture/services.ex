defmodule Wardmast.Screenshots.Capture.Services do
  @moduledoc """
  The services a capture boot needs besides the app (bd-3glf2a; design
  `docs/design/ui-screenshot-capture.md` §2, "Capture services"): a database, an object store,
  each declared in `screenshots.services` (`Wardmast.Screenshots.Config`).

  The app runs in the capture sandbox (`Wardmast.Screenshots.Capture.Sandbox`), which has no
  network, so it cannot start them or reach any on the host. Wardmast starts them, **host side,
  fresh for every boot** (the merge-base boot and the head boot each get their own, as does a
  named-seed boot), and hands the sandbox one endpoint per service: a host Unix socket that leads
  to the service. The sandbox turns that into `127.0.0.1:<port>` (and the declared `socket` path)
  inside the app's namespace. The app never sees podman, the host's loopback or the service by any
  other route.

  ## Callbacks

    * `start/2`: start every service for one boot and wait until each is ready. `{:ok, running}`
      with `running.endpoints` (`t:Wardmast.Screenshots.Capture.Sandbox.endpoint/0`, one per
      service, in config order) and a `handle` for `stop/1`; or `{:error, failure}` having left
      **nothing** running. `failure` names the service, says what went wrong and carries the tail
      of its log, which the capture records (`boot_failed`).
    * `stop/1`: stop and remove everything `start/2` started. Called on every exit path of the
      boot; must be safe to call once per `start/2` whatever happened in between.

  `context` is `%{role:, task_id:, opts:}`: `role` `"before"` or `"after"`, `opts` the
  implementation's options (the capture's `:services_opts`).

  The default is `Wardmast.Screenshots.Capture.Services.Podman`. A boot whose config declares no
  services never calls it.
  """

  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Screenshots.Config

  @type running :: %{endpoints: [Sandbox.endpoint()], handle: term()}
  @type failure :: %{
          service: String.t() | nil,
          reason: String.t(),
          log_tail: String.t() | nil
        }

  @callback start([Config.service()], context :: map()) ::
              {:ok, running()} | {:error, failure()}
  @callback stop(running()) :: :ok

  @doc "The services implementation `Capture.run/2` uses when the caller names none."
  @spec default() :: module()
  def default, do: Wardmast.Screenshots.Capture.Services.Podman
end
