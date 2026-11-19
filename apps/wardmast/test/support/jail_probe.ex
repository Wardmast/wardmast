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
  when `WARDMAST_TEST_REQUIRE_BWRAP=1`.
  """
  @spec skip_reason(:ok | {:error, term()}) :: String.t() | nil
  def skip_reason(:ok), do: nil

  def skip_reason(probe) do
    reason = "bwrap write jail unavailable on this host: #{inspect(probe)}"

    if System.get_env(@require_env) == "1",
      do: raise("#{@require_env}=1, but the real-bwrap tests cannot run: " <> reason),
      else: reason
  end
end
