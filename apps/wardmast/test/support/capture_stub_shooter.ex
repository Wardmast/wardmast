defmodule Wardmast.Test.CaptureStubShooter do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Shooter` that answers from `ctx.routes`, a
  `%{role => %{path => status}}` (a path not listed is a 404) and writes `"png:<role>:<path>"`
  as the image. `ctx.shoot_error` returns that error for every shot; `ctx.shoot_raise` raises.
  """
  @behaviour Wardmast.Screenshots.Capture.Shooter

  @impl true
  def shoot(%{ctx: ctx} = spec) do
    send(ctx.test_pid, {:shoot, spec.role, spec.path, spec.entry.viewport, spec.entry.theme})

    cond do
      msg = ctx[:shoot_raise] ->
        raise msg

      err = ctx[:shoot_error] ->
        {:error, err}

      true ->
        case ctx.routes |> Map.get(spec.role, %{}) |> Map.get(spec.path, 404) do
          200 ->
            File.write!(spec.out_file, "png:#{spec.role}:#{spec.path}")
            :ok

          status ->
            {:error, {:http_status, status}}
        end
    end
  end
end
