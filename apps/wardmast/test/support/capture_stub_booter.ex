defmodule Wardmast.Test.CaptureStubBooter do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Booter` that boots nothing. `ctx` (the `:ctx` capture option)
  carries `:test_pid` (every boot/stop is sent there, and the sandbox each boot was given) and
  optionally `:boot_failures`, a `%{role => detail}` of roles whose boot fails, and
  `:boot_delay_ms`. Each boot also reports the services and the deps cache it was handed. A boot hands the
  shooter `app: %{port: 1, role: role}`.
  """
  @behaviour Wardmast.Screenshots.Capture.Booter

  @impl true
  def boot(%{ctx: ctx} = spec) do
    send(ctx.test_pid, {:boot, spec.role, spec.seed, spec.checkout})
    send(ctx.test_pid, {:boot_sandbox, spec.role, Map.get(spec, :sandbox)})
    send(ctx.test_pid, {:boot_spec, spec.role, Map.get(spec, :services), Map.get(spec, :deps)})

    # A slow boot, to let a capture's budget run out after it.
    if ms = ctx[:boot_delay_ms], do: Process.sleep(ms)

    send(ctx.test_pid, {:checkout_entries, spec.role, spec.checkout |> File.ls!() |> Enum.sort()})
    send(ctx.test_pid, {:tree, spec.role, File.read!(Path.join(spec.checkout, "web/page.txt"))})

    case Map.get(Map.get(ctx, :boot_failures, %{}), spec.role) do
      nil ->
        {:ok,
         %{
           handle: {spec.role, spec.seed},
           base_url: "http://127.0.0.1:1",
           app: %{port: 1, role: spec.role}
         }}

      detail ->
        {:error, {:start, detail}}
    end
  end

  @impl true
  def stop(%{ctx: ctx} = _spec, {role, seed}) do
    send(ctx.test_pid, {:stop, role, seed})
    :ok
  end
end
