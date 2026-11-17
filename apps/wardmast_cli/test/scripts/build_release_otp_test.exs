defmodule WardmastCli.Scripts.BuildReleaseOtpTest do
  @moduledoc """
  Platform selection in `scripts/build-release-otp.sh` (bd-6uq02m, macOS P2-2).

  The script builds the ERTS the release bundles. On Linux it targets
  `linux-x86_64` (unchanged); on a macOS runner it must use OpenSSL's
  `darwin64-arm64-cc` target, pin a deployment target, and use `shasum`
  instead of `sha256sum`. `--print-config` reports those choices without
  building anything, and `ARB_OTP_UNAME_S` / `ARB_OTP_UNAME_M` stand in for
  `uname` so both platforms are testable from any host.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/build-release-otp.sh", __DIR__)

  defp config(env) do
    {out, 0} = System.cmd("bash", [@script, "--print-config"], env: env, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "Linux x86_64 keeps the original OpenSSL target and no deployment target" do
    cfg = config([{"ARB_OTP_UNAME_S", "Linux"}, {"ARB_OTP_UNAME_M", "x86_64"}])

    assert cfg["OPENSSL_TARGET"] == "linux-x86_64"
    assert cfg["DEPLOYMENT_TARGET"] == ""
    assert cfg["SHA256_TOOL"] == "sha256sum"
  end

  test "darwin arm64 uses darwin64-arm64-cc, a deployment target and shasum" do
    cfg = config([{"ARB_OTP_UNAME_S", "Darwin"}, {"ARB_OTP_UNAME_M", "arm64"}])

    assert cfg["OPENSSL_TARGET"] == "darwin64-arm64-cc"
    assert cfg["DEPLOYMENT_TARGET"] =~ ~r/^\d+\.\d+$/
    assert cfg["SHA256_TOOL"] == "shasum -a 256"
  end

  test "the deployment target can be overridden" do
    cfg =
      config([
        {"ARB_OTP_UNAME_S", "Darwin"},
        {"ARB_OTP_UNAME_M", "arm64"},
        {"MACOSX_DEPLOYMENT_TARGET", "14.0"}
      ])

    assert cfg["DEPLOYMENT_TARGET"] == "14.0"
  end

  test "an unsupported platform is refused" do
    {out, status} =
      System.cmd("bash", [@script, "--print-config"],
        env: [{"ARB_OTP_UNAME_S", "Darwin"}, {"ARB_OTP_UNAME_M", "ppc"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert out =~ "unsupported platform"
  end

  test "--print-versions is unchanged (CI cache key input)" do
    {out, 0} = System.cmd("bash", [@script, "--print-versions"])
    assert out =~ ~r/^OTP_VERSION=\S+ OPENSSL_VERSION=\S+\n$/
  end
end
