defmodule Wardmast.Worker.ReviewGate.NoVerdictCauseTest do
  @moduledoc """
  bd-3na3d7: a reviewer pass that ends with no `VERDICT:` line must say WHY. On
  mesaana (bd-c609gj, 2026-11-19) three reviewer passes ended "succeeded" ~4.5
  minutes in, mid `timeout 300 mix test`, and the escalation read a bare
  "review inconclusive". `NoVerdictCause` classifies the pass's exit from its
  exit status, the tail of its transcript and how long it ran against its budget.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Worker.ReviewGate.NoVerdictCause
  alias Wardmast.Worker.StopReason

  @budget_ms 20 * 60_000

  defp classify(attrs) do
    NoVerdictCause.classify(
      Map.merge(
        %{status: 0, lines: [], stop_reason: nil, elapsed_ms: 60_000, timeout_ms: @budget_ms},
        Map.new(attrs)
      )
    )
  end

  describe "classify/1" do
    test "a clean exit whose last event is an unanswered tool call is a mid-tool-call exit" do
      lines = [
        "reading the diff",
        "⏵ Read(lib/foo.ex)",
        "⏴ defmodule Foo do",
        "⏵ Bash(timeout 300 mix test test/foo_test.exs)"
      ]

      assert %{cause: :exited_mid_tool_call, text: text} = classify(lines: lines)
      assert text =~ "mix test"
      assert text =~ "tool call"
      assert text =~ "exit 0"
    end

    test "the session footer after an unanswered tool call does not hide it" do
      lines = [
        "reading the diff",
        "⏵ Bash(timeout 300 mix test test/foo_test.exs)",
        "⚙ claude session success · 270.1s · $0.80"
      ]

      assert %{cause: :exited_mid_tool_call, text: text} = classify(lines: lines)
      assert text =~ "timeout 300 mix test"

      assert %{cause: :exited_mid_tool_call} =
               classify(lines: lines ++ ["", "arb done"])
    end

    test "a footer after an answered tool call is still a plain no-verdict exit" do
      lines = ["⏵ Bash(mix test)", "⏴ ok", "⚙ claude session success · 12.0s · $0.10"]
      assert %{cause: :ended_without_verdict} = classify(lines: lines)
    end

    test "a tool call whose result arrived is not mid-call" do
      lines = ["⏵ Bash(mix test)", "⏴ 3 tests, 0 failures", "I am done reviewing."]
      assert %{cause: :ended_without_verdict} = classify(lines: lines)
    end

    test "a clean exit with no tool call in flight is an ended-without-verdict" do
      assert %{cause: :ended_without_verdict, text: text} =
               classify(lines: ["looks fine to me", "arb done"])

      assert text =~ "without printing a VERDICT"
    end

    test "a signal-killed reviewer is `killed`, naming the signal" do
      reason = %StopReason{
        category: :killed,
        summary: "agent subprocess was killed by signal 9",
        exit_status: 137,
        signal: 9
      }

      assert %{cause: :killed, text: text} = classify(status: 137, stop_reason: reason)
      assert text =~ "killed"
      assert text =~ "signal 9"
    end

    test "an OOM-killed reviewer is `killed` with the memory cap named" do
      reason = StopReason.memory_cap_exceeded(%{max: "6g", peak: nil}, 137)

      assert %{cause: :killed, text: text} = classify(status: 137, stop_reason: reason)
      assert text =~ "memory cap"
    end

    test "a pass that ran out its wall-clock budget is `budget_exceeded`" do
      assert %{cause: :budget_exceeded, text: text} =
               classify(elapsed_ms: @budget_ms, status: nil, lines: ["⏵ Bash(mix test)"])

      assert text =~ "20 min"
      assert text =~ "budget"
    end

    test "an unclassified non-zero exit is `crashed` with the exit code" do
      assert %{cause: :crashed, text: text} = classify(status: 2, lines: ["boom"])
      assert text =~ "exit 2"
    end

    test "an abandoned async wait keeps its own cause" do
      reason = %StopReason{category: :async_wait_abandoned, summary: "armed a wait"}
      assert %{cause: :async_wait_abandoned} = classify(stop_reason: reason)
    end

    test "a mid-tool-call exit that ran its whole budget is a budget cut-off, not a clean exit" do
      assert %{cause: :budget_exceeded} =
               classify(elapsed_ms: @budget_ms + 1_000, lines: ["⏵ Bash(mix test)"])
    end

    test "unknown elapsed time never claims a budget cut-off" do
      assert %{cause: :exited_mid_tool_call} =
               classify(elapsed_ms: nil, lines: ["⏵ Bash(mix test)"])
    end
  end

  describe "render/1" do
    test "leads with the cause and the elapsed time" do
      cause = classify(lines: ["⏵ Bash(mix test)"], elapsed_ms: 270_000)
      assert NoVerdictCause.render([cause]) =~ "ended after 4m30s"
    end

    test "names every pass's cause when several passes ended without a verdict" do
      a = classify(lines: ["⏵ Bash(mix test)"])

      b =
        classify(
          status: 137,
          stop_reason: %StopReason{category: :killed, summary: "k", signal: 9}
        )

      text = NoVerdictCause.render([a, b])
      assert text =~ "Pass 1"
      assert text =~ "Pass 2"
    end

    test "renders nothing for no passes" do
      assert NoVerdictCause.render([]) == ""
    end
  end
end
