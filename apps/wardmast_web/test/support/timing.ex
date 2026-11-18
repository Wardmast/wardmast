defmodule WardmastWeb.Test.Timing do
  @moduledoc """
  Scale a hand-written wall-clock wait budget (`render_async/2`, `assert_receive/3`)
  to the host the suite runs on.

  `scripts/test_host_tuning.exs` raises ExUnit's `assert_receive_timeout` from its
  100 ms default to 1 s on darwin (the macOS smoke job's slow runners). A literal
  wait does not read that setting, so it gets the same factor from here: 1 where
  the default is untouched, 10 where it is raised. Mirrors `Wardmast.Test.Timing`
  in the core app (not on this app's test path).
  """

  @default_ms 100

  @doc "`ms` multiplied by how much slower than a dev box the configured host is."
  @spec scale(non_neg_integer()) :: non_neg_integer()
  def scale(ms) do
    configured = Application.get_env(:ex_unit, :assert_receive_timeout, @default_ms)
    ms * max(1, div(configured, @default_ms))
  end
end
