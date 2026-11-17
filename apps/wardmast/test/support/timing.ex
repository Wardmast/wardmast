defmodule Wardmast.Test.Timing do
  @moduledoc """
  Scale a hand-written wall-clock wait budget to the host the suite runs on.

  `scripts/test_host_tuning.exs` raises ExUnit's `assert_receive_timeout` from its
  100 ms default to 1 s on darwin (the macOS smoke job's 3-core runners), so
  LiveView's `render_async/2`, `assert_push/2` and plain `assert_receive` stop
  missing their first reply. A poll loop with its own deadline
  (`wait_until(fun, 1_000)`) does not read that setting, so it gets the same
  factor from here: 1 where the default is untouched, 10 where it is raised.
  """

  @default_ms 100

  @doc "`ms` multiplied by how much slower than a dev box the configured host is."
  @spec scale(non_neg_integer()) :: non_neg_integer()
  def scale(ms) do
    configured = Application.get_env(:ex_unit, :assert_receive_timeout, @default_ms)
    ms * max(1, div(configured, @default_ms))
  end
end
