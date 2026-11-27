defmodule Wardmast.Test.CaptureStubShooter do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Shooter` that answers from `ctx.routes`, a
  `%{role => %{path => status}}` (a path not listed is a 404) and writes `"png:<role>:<path>"`
  as the image. `ctx.shoot_error` returns that error for every shot; `ctx.shoot_raise` raises. `ctx.dom_text` is the page text it reports (see `dom_text/2`).
  Each shot also reports the sandbox, the boot's app and the per-shot dir it was handed.
  """
  @behaviour Wardmast.Screenshots.Capture.Shooter

  @impl true
  def shoot(%{ctx: ctx} = spec) do
    send(ctx.test_pid, {:shoot, spec.role, spec.path, spec.entry.viewport, spec.entry.theme})
    scratch = Map.get(spec, :scratch)

    send(
      ctx.test_pid,
      {:shot_env, spec.role, Map.get(spec, :sandbox), Map.get(spec, :app), scratch,
       is_binary(scratch) and File.dir?(scratch)}
    )

    cond do
      msg = ctx[:shoot_raise] ->
        raise msg

      err = ctx[:shoot_error] ->
        {:error, err}

      true ->
        case ctx.routes |> Map.get(spec.role, %{}) |> Map.get(spec.path, 404) do
          200 ->
            File.write!(spec.out_file, "png:#{spec.role}:#{spec.path}")
            dom_text(ctx, spec.role)

          {:redirect, final} ->
            {:error, {:redirected, spec.path, final}}

          status ->
            {:error, {:http_status, status}}
        end
    end
  end

  # What the page showed: `ctx.dom_text` is a list for every shot, a `%{role => list}`, or `:none`
  # for a shooter that reports no text at all (which the capture step must not trust).
  defp dom_text(ctx, role) do
    case Map.get(ctx, :dom_text, []) do
      :none -> :ok
      %{} = by_role -> {:ok, %{text: Map.get(by_role, role, [])}}
      texts -> {:ok, %{text: texts}}
    end
  end
end
