defmodule Wardmast.Test.FailingSessionRunner do
  @moduledoc """
  An `Wardmast.Sessions.Runner` whose every command fails.

  The counterpart to `Wardmast.Test.NoopRunner`, and for the same reason: a
  caller in its own process (a LiveView, a channel) cannot be handed
  `Wardmast.Test.SessionRunnerStub`'s script, which lives in the *calling*
  process's dictionary. This is how a test makes `Wardmast.Sessions.launch/1`
  fail the way a missing `systemd-run` would, so the UI's failure path is
  exercised rather than assumed.
  """

  @behaviour Wardmast.Sessions.Runner

  @impl Wardmast.Sessions.Runner
  def run(command, _args, _opts), do: {"#{command}: No such file or directory", 127}
end
