defimpl Inspect, for: Wardmast.Worker.State do
  # bd-akp9ae: a Worker's state, printed anywhere (a log line, the arguments in a crash
  # report's stacktrace), masks the secrets it holds (`Wardmast.Worker.StateRedaction`).
  def inspect(state, opts) do
    state
    |> Wardmast.Worker.StateRedaction.mask()
    |> Inspect.Any.inspect(opts)
  end
end
