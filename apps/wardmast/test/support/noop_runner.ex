defmodule Wardmast.Test.NoopRunner do
  @moduledoc """
  An `Wardmast.Sessions.Runner` that runs nothing and always succeeds.

  `Wardmast.Test.SessionRunnerStub` keeps its script and its recorded calls in
  the **caller's** process dictionary, which is exactly right when the caller
  is the test — and useless when the caller is a channel or a reader in its own
  process. Those tests do not need the argv (that is asserted in
  `Wardmast.Sessions.Terminal.TmuxTest` and phase 1's suite); they need
  `Wardmast.Sessions.kill/2` to reach its database effects without a real
  `systemctl --user stop` running on the host that is also running the live
  coordinator.
  """

  @behaviour Wardmast.Sessions.Runner

  @impl Wardmast.Sessions.Runner
  def run(_command, _args, _opts), do: {"", 0}
end
