defmodule Wardmast.Worker.TestSignal do
  @moduledoc """
  The "tests not run" signal (bd-7m35lc): did a worker that reached for `run_tests`
  ever get a passing or failing result out of it?

  A Codex implementer on a repo with a per-worker test env could not start any
  test, said so, and still reported the branch clean. Nothing at completion knew.
  Every `run_tests` call is recorded on the run's meta as an outcome:

    * `:ran` — the suite ran and reported pass or fail;
    * `:not_run` — it could not give a result (test env unavailable, the
      environment could not exec).

  `not_run?/1` is true when the worker tried and never got a `:ran`. A worker that
  never called `run_tests` (it ran `mix test` in its shell) is not flagged: the
  signal is about a *known* inability, not an unobserved one. The commit gate's
  send-back prompt and the ReviewGate's reviewer prompt both carry `note/0`.
  """

  @type outcome :: :ran | :not_run

  @doc "Fold `outcome` into the run's meta."
  @spec record(map() | nil, outcome()) :: map()
  def record(meta, outcome) when outcome in [:ran, :not_run] do
    meta = meta || %{}
    counts = Map.get(meta, :test_outcomes, %{ran: 0, not_run: 0})
    Map.put(meta, :test_outcomes, Map.update(counts, outcome, 1, &(&1 + 1)))
  end

  @doc "Did the worker try `run_tests` and never get a passing or failing result?"
  @spec not_run?(map() | nil) :: boolean()
  def not_run?(meta) do
    case Map.get(meta || %{}, :test_outcomes) do
      %{ran: 0, not_run: n} when n > 0 -> true
      _ -> false
    end
  end

  @doc "The outcome of a `run_tests` result."
  @spec outcome(map()) :: outcome()
  def outcome(%{ran?: true, report: %{status: status}}) when status in [:passed, :failed],
    do: :ran

  def outcome(_result), do: :not_run

  @doc "The warning carried by the commit-gate prompt and the reviewer prompt."
  @spec note() :: String.t()
  def note do
    "TESTS NOT RUN: the author's `run_tests` calls never produced a passing or failing " <>
      "result (the test env could not be provisioned). Treat its claim " <>
      "that the work is verified as unproven: do not accept \"done and clean\" on its " <>
      "word, check `git status` for uncommitted work, and say in your verdict that no " <>
      "test result backs the change."
  end

  @doc "`note/0` as a block for a prompt when `meta` says tests were not run, else `\"\"`."
  @spec block(map() | nil) :: String.t()
  def block(meta), do: if(not_run?(meta), do: "\n" <> note() <> "\n", else: "")
end
