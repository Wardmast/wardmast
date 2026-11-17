defmodule WardmastCli.Supervisor.NoDirectServiceManagerCallsTest do
  # Guard for the Supervisor seam: the only places in the CLI that spawn (or
  # build a command line for) a service manager are the backends —
  # `Supervisor.Systemd` (systemctl / loginctl / journalctl) and
  # `Supervisor.Launchd` (launchctl). Prose in docs and advice strings is fine;
  # a *quoted executable name* is what a spawn call site looks like.
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @backends [
    Path.join(@lib, "wardmast_cli/supervisor/systemd.ex"),
    Path.join(@lib, "wardmast_cli/supervisor/launchd.ex")
  ]
  @spawn_literal ~r/"(systemctl|loginctl|journalctl|launchctl)"/

  test "no CLI module outside the Supervisor backends names a service-manager executable" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(&1 in @backends))
      |> Enum.filter(&(&1 |> File.read!() |> String.match?(@spawn_literal)))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end
end
