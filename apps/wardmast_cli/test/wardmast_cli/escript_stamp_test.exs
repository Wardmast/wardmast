defmodule WardmastCli.EscriptStampTest do
  @moduledoc """
  bd-59m96o: the `arb` escript records the Erlang/OTP release it was compiled
  on in its comment line (`%% arb-otp=29`). A BEAM file loads only on that
  release or a newer one, so the server reads the stamp to give worker images a
  runtime arb can load (`Wardmast.Worker.ArbCli.built_otp/1`), and the launcher
  that runs arb inside a container reads it to refuse an older Erlang clearly.
  """
  use ExUnit.Case, async: true

  test "the escript is named `ward` and its comment line carries the release it is compiled on" do
    assert Mix.Project.config()[:escript][:name] == "ward"
    assert Mix.Project.config()[:escript][:comment] == "arb-otp=#{System.otp_release()}"
  end

  test "the release workflow builds and publishes `ward` plus `ward.sha256`" do
    workflow_path = Path.expand("../../../../.github/workflows/release.yml", __DIR__)
    workflow = File.read!(workflow_path)

    assert workflow =~ "sha256sum apps/wardmast_cli/ward > ward.sha256"
    assert workflow =~ "apps/wardmast_cli/ward"
    assert workflow =~ "ward.sha256"
    refute workflow =~ "sha256sum apps/wardmast_cli/arb"
  end
end
