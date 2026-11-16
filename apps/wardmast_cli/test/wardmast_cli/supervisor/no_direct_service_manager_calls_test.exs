defmodule WardmastCli.Supervisor.NoDirectServiceManagerCallsTest do
  # Guard for the Supervisor seam: the only place in the CLI that spawns (or
  # builds a command line for) systemctl / loginctl / journalctl is
  # `WardmastCli.Supervisor.Systemd`. Prose in docs and advice strings is fine;
  # a *quoted executable name* is what a spawn call site looks like.
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)
  @allowed Path.join(@lib, "wardmast_cli/supervisor/systemd.ex")
  @spawn_literal ~r/"(systemctl|loginctl|journalctl)"/

  test "no CLI module outside Supervisor.Systemd names a service-manager executable" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @allowed))
      |> Enum.filter(&(&1 |> File.read!() |> String.match?(@spawn_literal)))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end
end
