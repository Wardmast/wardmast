defmodule Wardmast.Worker.ReviewGate.NoVerdictCause do
  @moduledoc """
  Why a reviewer pass ended with no `VERDICT:` line (bd-3na3d7).

  A pass that exits without a verdict used to escalate as a bare "review
  inconclusive", whatever actually happened to it. On mesaana (bd-c609gj,
  2026-11-19) three reviewer passes ended "succeeded" about 4.5 minutes in, each
  with its transcript stopping in the middle of a `timeout 300 mix test` Bash
  call: the session was not a reviewer that "chose" not to judge, it was a
  session that ended under its own tool call. The gate could not tell those
  apart, so a coordinator had to read the transcript to find out.

  `classify/1` reads what the gate already knows when a pass exits — the exit
  status, the `StopReason` the transcript classified to, the tail of the
  transcript and how long the pass ran against its budget — and names one cause:

    * `:killed` — a signal (or the OOM killer) ended the process;
    * `:budget_exceeded` — the pass ran its whole wall-clock budget;
    * `:async_wait_abandoned` — the reviewer armed a background wait and yielded;
    * `:crashed` — a non-zero exit with no known signature;
    * `:exited_mid_tool_call` — a clean exit while the last tool call had no
      result yet (the CLI ended the session under the call);
    * `:ended_without_verdict` — a clean exit that simply never printed one.

  `render/1` turns the causes of a round's passes into the sentence the
  escalation carries. Pure: no process, no I/O.
  """

  alias Wardmast.Worker.StopReason

  @tool_call_prefix "⏵ "
  @max_call_chars 160

  @type cause_name ::
          :killed
          | :budget_exceeded
          | :async_wait_abandoned
          | :crashed
          | :exited_mid_tool_call
          | :ended_without_verdict

  @type t :: %{
          cause: cause_name(),
          text: String.t(),
          elapsed_ms: non_neg_integer() | nil,
          status: integer() | nil
        }

  @type input :: %{
          required(:status) => integer() | nil,
          required(:lines) => [String.t()],
          required(:stop_reason) => StopReason.t() | nil,
          required(:elapsed_ms) => non_neg_integer() | nil,
          required(:timeout_ms) => pos_integer() | nil
        }

  @doc "Classify a no-verdict pass exit. `lines` is the transcript, oldest first."
  @spec classify(input()) :: t()
  def classify(%{status: status, elapsed_ms: elapsed_ms} = input) do
    {cause, text} = cause_and_text(input)
    %{cause: cause, text: text, elapsed_ms: elapsed_ms, status: status}
  end

  defp cause_and_text(%{stop_reason: %StopReason{category: :memory_cap_exceeded}} = input) do
    {:killed,
     "the reviewer process exceeded its memory cap and was OOM-killed" <> exit_suffix(input)}
  end

  defp cause_and_text(%{stop_reason: %StopReason{category: :killed} = reason} = input) do
    {:killed, "the reviewer process was killed" <> signal_note(reason) <> exit_suffix(input)}
  end

  defp cause_and_text(%{status: status} = input)
       when is_integer(status) and status > 128 and status <= 192 do
    {:killed,
     "the reviewer process was killed by signal #{status - 128} (exit #{status})" <>
       budget_hint(input)}
  end

  defp cause_and_text(input) do
    cond do
      budget_spent?(input) ->
        {:budget_exceeded,
         "the pass ran out its #{minutes(input.timeout_ms)} min wall-clock budget " <>
           "(review_gate.timeout_ms) before printing a VERDICT" <> in_flight_note(input)}

      match?(%StopReason{category: :async_wait_abandoned}, input.stop_reason) ->
        {:async_wait_abandoned,
         "the reviewer armed a background wait (Monitor / ScheduleWakeup / backgrounded " <>
           "command) and ended its turn to wait for it; a headless session cannot be woken"}

      is_integer(input.status) and input.status != 0 ->
        {:crashed, "the reviewer process crashed (exit #{input.status}) without a VERDICT"}

      true ->
        clean_exit(input)
    end
  end

  defp clean_exit(input) do
    case in_flight_call(input.lines) do
      nil ->
        {:ended_without_verdict, "the reviewer exited without printing a VERDICT line (exit 0)"}

      call ->
        {:exited_mid_tool_call,
         "the reviewer session ended (exit 0) while a tool call was still in flight — " <>
           "last call: `#{call}` — so no verdict was printed. A build or test command that " <>
           "outlives the CLI's tool-call limit ends the session this way"}
    end
  end

  # The transcript's last meaningful line is a tool-call header ("⏵ Bash(...)")
  # with no result line ("⏴ ...") after it: the call never answered.
  #
  # The session closes with a `⚙ claude session <status> · Ns · $X` footer (and a
  # reviewer may print `arb done`) AFTER the unanswered call, so those trailing
  # lines are skipped before the last line is read — otherwise the footer hides
  # the call on every clean exit.
  defp in_flight_call(lines) do
    lines
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or footer_line?(&1)))
    |> List.last()
    |> case do
      @tool_call_prefix <> call -> String.slice(call, 0, @max_call_chars)
      _ -> nil
    end
  end

  defp footer_line?("⚙" <> _), do: true
  defp footer_line?(line), do: Regex.match?(~r/\barb done\b/, line)

  defp in_flight_note(input) do
    case in_flight_call(input.lines) do
      nil -> ""
      call -> "; its last tool call (`#{call}`) had not answered"
    end
  end

  defp budget_hint(input) do
    if budget_spent?(input),
      do: "; it had run its whole #{minutes(input.timeout_ms)} min budget",
      else: ""
  end

  defp budget_spent?(%{elapsed_ms: elapsed, timeout_ms: budget})
       when is_integer(elapsed) and is_integer(budget) and budget > 0,
       do: elapsed >= budget

  defp budget_spent?(_input), do: false

  defp signal_note(%StopReason{signal: signal}) when is_integer(signal),
    do: " by signal #{signal}"

  defp signal_note(_reason), do: ""

  defp exit_suffix(%{status: status}) when is_integer(status), do: " (exit #{status})"
  defp exit_suffix(_input), do: ""

  defp minutes(ms), do: max(div(ms, 60_000), 1)

  @doc """
  The escalation sentence(s) for a round's no-verdict passes (oldest first), or
  `""` for none.
  """
  @spec render([t()]) :: String.t()
  def render([]), do: ""

  def render([single]), do: "Reviewer pass ended#{elapsed_phrase(single)}: #{single.text}."

  def render(causes) do
    "No pass produced a verdict. " <>
      (causes
       |> Enum.with_index(1)
       |> Enum.map_join(" ", fn {cause, n} ->
         "Pass #{n} ended#{elapsed_phrase(cause)}: #{cause.text}."
       end))
  end

  defp elapsed_phrase(%{elapsed_ms: ms}) when is_integer(ms) and ms >= 0 do
    secs = div(ms, 1000)
    " after #{div(secs, 60)}m#{String.pad_leading(Integer.to_string(rem(secs, 60)), 2, "0")}s"
  end

  defp elapsed_phrase(_cause), do: ""
end
