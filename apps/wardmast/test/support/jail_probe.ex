defmodule Wardmast.Test.JailProbe do
  @moduledoc """
  The skip gate of the real-bwrap tests (bd-bzhpgi).

  A test that runs a real `bwrap` skips where `Wardmast.Worker.Jail.probe/0`
  fails: no bwrap, no unprivileged user namespaces, or Ubuntu's AppArmor userns
  restriction. Skipping quietly is how `qwen/jail_bwrap_test.exs` stayed broken
  through every ubuntu-24.04 CI run, where it never ran (#1541). CI's `jail` job
  sets `WARDMAST_TEST_REQUIRE_BWRAP=1`, which turns that skip into a failure:

      @bwrap_skip JailProbe.skip_reason(Jail.probe())
      if @bwrap_skip, do: @moduletag(skip: @bwrap_skip)
  """

  @require_env "WARDMAST_TEST_REQUIRE_BWRAP"

  @doc """
  `nil` when the jail runs on this host, else the reason to skip. Raises instead
  when `WARDMAST_TEST_REQUIRE_BWRAP=1`. `what` names the bwrap sandbox the probe
  was for (the write jail by default; the capture sandbox passes its own).
  """
  @spec skip_reason(:ok | {:error, term()}, String.t()) :: String.t() | nil
  def skip_reason(probe, what \\ "bwrap write jail")

  def skip_reason(:ok, _what), do: nil

  def skip_reason(probe, what) do
    reason = "#{what} unavailable on this host: #{inspect(probe)}"

    if System.get_env(@require_env) == "1",
      do: raise("#{@require_env}=1, but the real-bwrap tests cannot run: " <> reason),
      else: reason
  end

  @doc """
  On CI (`CI` set, as GitHub Actions does), print what a jailed stub reported
  (its `MOUNTINFO:` lines, each attack's raw error) under `[jail evidence]`: a
  passing run prints nothing else, and its log is the evidence that the jail
  held on that runner. A no-op elsewhere.
  """
  @spec evidence(String.t(), String.t()) :: :ok
  def evidence(label, out) do
    if System.get_env("CI") in ["true", "1"],
      do: IO.puts("\n[jail evidence] #{label}\n" <> String.trim_trailing(out))

    :ok
  end
end
