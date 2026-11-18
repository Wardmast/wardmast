defmodule Wardmast.Sessions.Runner do
  @moduledoc """
  The one place session control operations reach the operating system
  (bd-bpt0ag, phase 1 of `docs/browser-hosted-coordinator-sessions.md`).

  Every session operation — launch, kill, enumerate — is a **synchronous
  shell-out that returns**: it runs `systemd-run` / `tmux` / `systemctl`,
  collects the output, and hands back `{output, exit_status}`. Nothing is
  retained. That is the deliberate opposite of `Port.open`, which would leave
  the BEAM owning a handle on the child, and it is what makes RFC §4.3's claim
  ("Wardmast holds no long-lived handle to the PTY") a property of the code
  rather than a promise — see `Wardmast.Sessions.NoPtyHandleTest`.

  Being a behaviour makes it the test seam as well: `Wardmast.Sessions` takes a
  `:runner` option, so the lifecycle logic is exercised against a scripted
  `systemctl` / `tmux` without a systemd user manager in sight
  (`Wardmast.Test.SessionRunnerStub`).

  ## Resolution order

  `Wardmast.Sessions.runner/1`: the `:runner` option, then
  `config :wardmast, :sessions_runner`, then the OS default:
  `Wardmast.Sessions.Runner.Darwin` on macOS (no systemd — it implements the
  `systemd-run` / `systemctl` verbs over detached tmux + a pidfile, bd-a1pnnv),
  `Wardmast.Sessions.Runner.Host` everywhere else.
  """

  @doc """
  Run `command` with `args` and return `{collected_output, exit_status}`.

  Implementations MUST be synchronous and MUST NOT retain anything about the
  child process after returning. `opts` carries `System.cmd/3` options —
  `:env` and `:stderr_to_stdout` are the two `Wardmast.Sessions` passes.
  """
  @callback run(command :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {String.t(), non_neg_integer()}
end
