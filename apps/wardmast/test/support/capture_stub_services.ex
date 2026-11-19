defmodule Wardmast.Test.CaptureStubServices do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Services` that starts nothing (bd-3glf2a). `context.opts` (the
  capture's `:services_opts`) carries `:test_pid`, which is told every start and stop, and
  optionally `:fail`, a `%{role => failure}` of roles whose services do not come up.
  """

  @behaviour Wardmast.Screenshots.Capture.Services

  @impl true
  def start(services, %{role: role, opts: opts} = context) do
    names = Enum.map(services, & &1.name)
    handle = {role, make_ref()}
    send(Keyword.fetch!(opts, :test_pid), {:services_start, role, names, handle})
    send(Keyword.fetch!(opts, :test_pid), {:services_deadline, role, Map.get(context, :deadline)})

    case Map.get(Keyword.get(opts, :fail, %{}), role) do
      {:exit, reason} ->
        exit(reason)

      nil ->
        endpoints =
          for svc <- services,
              do: %{
                name: svc.name,
                port: svc.port,
                socket: "/sock/#{role}/#{svc.name}",
                sandbox_socket: svc.socket
              }

        {:ok, %{endpoints: endpoints, handle: {handle, opts}}}

      failure ->
        {:error, failure}
    end
  end

  @impl true
  def stop(%{handle: {handle, opts}}) do
    send(Keyword.fetch!(opts, :test_pid), {:services_stop, handle})
    if reason = Keyword.get(opts, :stop_exit), do: exit(reason)
    :ok
  end
end
