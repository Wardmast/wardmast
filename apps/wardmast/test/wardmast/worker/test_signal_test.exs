defmodule Wardmast.Worker.TestSignalTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.PrepushCheck
  alias Wardmast.Worker.TestSignal

  test "not_run? only when run_tests was tried and never gave a result" do
    refute TestSignal.not_run?(nil)
    refute TestSignal.not_run?(%{})
    meta = TestSignal.record(%{}, :not_run)
    assert TestSignal.not_run?(meta)
    refute meta |> TestSignal.record(:ran) |> TestSignal.not_run?()
  end

  test "outcome classifies a run result" do
    assert TestSignal.outcome(%{ran?: true, report: %{status: :passed}}) == :ran
    assert TestSignal.outcome(%{ran?: true, report: %{status: :failed}}) == :ran
    assert TestSignal.outcome(%{ran?: true, report: %{status: :error}}) == :not_run
    assert TestSignal.outcome(%{ran?: true, report: %{status: :timeout}}) == :not_run
  end

  test "the commit gate's send-back prompt carries the signal" do
    meta = TestSignal.record(%{branch: "b"}, :not_run)
    detail = %{status: :failed, output: "x", command: "c", exit_status: 1}
    assert PrepushCheck.nudge_prompt("bd-1", meta, detail) =~ "TESTS NOT RUN"
    refute PrepushCheck.nudge_prompt("bd-1", %{branch: "b"}, detail) =~ "TESTS NOT RUN"
  end

  test "block/1 is empty unless tests were not run" do
    assert TestSignal.block(%{}) == ""
    assert TestSignal.block(TestSignal.record(%{}, :not_run)) =~ "TESTS NOT RUN"
  end
end
