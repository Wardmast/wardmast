defmodule Wardmast.Worker.ReviewGateNoVerdictCauseTest do
  @moduledoc """
  bd-3na3d7: the gate's final no-verdict escalation names WHY the reviewer ended
  (killed / budget / mid tool call ...) instead of a bare "no parseable VERDICT".
  Tested at the seam where a pass exit becomes the parked escalation text:
  `ReviewGate.note_no_verdict_cause/4` records the cause on the gate state and
  `ReviewGate.no_verdict_scan_message/1` renders it.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Worker.ReviewGate
  alias Wardmast.Worker.StopReason

  defp state(attrs \\ %{}) do
    Map.merge(
      %{
        verdict_scan: %{memory: 4, durable: 4, run_id: "run-1"},
        verdict_scans: [%{memory: 4, durable: 4, run_id: "run-1"}],
        denied_commands: [],
        no_verdict_causes: [],
        pass_started_ms: System.monotonic_time(:millisecond) - 270_000,
        timeout_ms: 20 * 60_000
      },
      attrs
    )
  end

  test "a reviewer cut off mid `mix test` is reported as such, not a bare inconclusive" do
    lines =
      Enum.reverse([
        "reading the diff",
        "⏵ Bash(timeout 300 mix test test/foo_test.exs)"
      ])

    msg =
      state()
      |> ReviewGate.note_no_verdict_cause(0, lines, nil)
      |> ReviewGate.no_verdict_scan_message()

    assert msg =~ "tool call was still in flight"
    assert msg =~ "timeout 300 mix test"
    assert msg =~ "ended after 4m"
    # the pre-existing scan counts and transcript pointer are still there
    assert msg =~ "no parseable VERDICT line"
    assert msg =~ "Durable transcript"
  end

  test "a killed reviewer says killed, with the signal" do
    reason = %StopReason{category: :killed, summary: "k", exit_status: 137, signal: 9}

    msg =
      state()
      |> ReviewGate.note_no_verdict_cause(137, ["working"], reason)
      |> ReviewGate.no_verdict_scan_message()

    assert msg =~ "killed by signal 9"
  end

  test "every pass's cause is named once a re-prompt also came back empty" do
    msg =
      state()
      |> ReviewGate.note_no_verdict_cause(0, ["⏵ Bash(mix test)"], nil)
      |> ReviewGate.note_no_verdict_cause(137, ["x"], %StopReason{
        category: :killed,
        summary: "k",
        signal: 9
      })
      |> ReviewGate.no_verdict_scan_message()

    assert msg =~ "Pass 1"
    assert msg =~ "Pass 2"
  end

  test "with no recorded cause the message is the old one" do
    msg = ReviewGate.no_verdict_scan_message(state())
    refute msg =~ "Reviewer pass ended"
    assert msg =~ "no parseable VERDICT line"
  end
end
