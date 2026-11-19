defmodule Wardmast.Worker.ReviewGate.ScreenshotGate do
  @moduledoc """
  The ReviewGate's screenshot step (bd-84latk, GitHub #1328; design
  `docs/design/ui-screenshot-capture.md` §2, §5.4). It runs after the CI gate and before a reviewer
  is dispatched, for a repo that has a `screenshots` config, and decides one of four things:

  | outcome of `Wardmast.Screenshots.Capture` | the gate |
  |---|---|
  | the change does not touch `ui_paths` | proceeds, nothing added (today's behaviour) |
  | pairs were captured, or the worker declared a `skip` | proceeds, the pairs (file paths) or the skip reason go into the reviewer's brief |
  | this host cannot sandbox the capture ("capture needs a sandbox", bd-bhrsdv) | proceeds; the reviewer is told no screenshots were taken and why, and that it is not the worker's doing. Nothing was booted |
  | a **worker fault**: no manifest, an invalid manifest, a named route that errors | sends the change back to the worker with an instruction (`{:send_back, findings}`) |
  | an **infrastructure fault**: the app would not boot, no Chromium, the checkout or diff failed, the budget ran out | escalates to the coordinator (`{:escalate, message}`) and does **not** loop the worker |

  A repo with no `screenshots` config (or one that does not validate, or a gate with no worktree)
  is `:skip`: the gate behaves exactly as it did before this step existed.

  `plan/2` and `route/1` are pure; `run/2` is what the gate runs in a task, because a capture boots the
  app twice and can take minutes.

  Classification lives in `classify/1`: `:manifest_missing`, `:manifest_invalid` and `:route_error`
  are the worker's (it wrote the plan); every other `Wardmast.Screenshots.Capture.Failure` code is
  infrastructure. `:shot_failed` is infrastructure because it cannot tell a bad selector from a
  browser crash, and looping a worker over a crash is the worse mistake.
  """

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.PlanCheck

  # The line a worker prints to declare a fix with no file change (see ReviewGate's
  # `@non_file_fix_marker`): the plan file is gitignored, so adding it moves no head.
  @no_file_change "NO-FILE-CHANGE:"
  @plan_file ".arbiter/screenshots.json"

  @worker_codes [:manifest_missing, :manifest_invalid, :route_error]

  @type job :: %{input: map(), config: Config.t(), opts: keyword()}
  @type outcome :: Capture.run_outcome()
  @type routed ::
          {:proceed, String.t() | nil}
          | {:send_back, String.t()}
          | {:escalate, String.t()}

  @doc "The relative path of the worker's plan, inside its worktree."
  @spec plan_file() :: String.t()
  def plan_file, do: @plan_file

  @doc """
  Whether (and how) to run the step for `state` in `workspace`.

  `:skip` leaves the gate as it was; `{:cached, outcome}` reuses the outcome already read for this
  head; `{:run, job}` is a capture to run with `run/2`.
  """
  @spec plan(map(), term()) :: :skip | {:cached, outcome()} | {:run, job()}
  def plan(%{worktree_path: wt} = state, workspace) when is_binary(wt) do
    with {:ok, %Config{} = config} <- Config.resolve(workspace, Map.get(state, :repo)),
         head when is_binary(head) <- Map.get(state, :head_sha),
         base when is_binary(base) <- Map.get(state, :base_sha) do
      case Map.get(state, :screenshot_checked) do
        %{head_sha: ^head, outcome: outcome} -> {:cached, outcome}
        _ -> {:run, job(state, config, base, head)}
      end
    else
      _ -> :skip
    end
  end

  def plan(_state, _workspace), do: :skip

  defp job(state, config, base, head) do
    wt = state.worktree_path

    out_dir =
      Path.join([System.tmp_dir!(), "arbiter-review-screenshots", state.task_id, head])

    %{
      config: config,
      input: %{
        task_id: state.task_id,
        repo_path: wt,
        base_sha: base,
        head_sha: head,
        config: config,
        plan_path: plan_path(state, wt),
        out_dir: out_dir
      },
      opts: Map.get(state, :screenshot_opts, [])
    }
  end

  # The plan the commit gate checked (stored outside the worktree) feeds the capture, so a plan
  # edited after `arb done` is not the one shot; no stored copy falls back to the live file.
  defp plan_path(state, wt) do
    root = Map.get(state, :screenshot_plan_root, PlanCheck.store_root())

    case PlanCheck.stored_sha(root, state.task_id) do
      {:ok, _sha} -> PlanCheck.stored_path(root, state.task_id)
      :error -> Path.join(wt, @plan_file)
    end
  end

  @doc """
  Run the capture for `job`. `capture` is `(input, opts -> outcome)` (default `Capture.run/2`).

  Never raises: a capture that crashes is an infrastructure failure, so a broken browser stack
  cannot take the ReviewGate down with it.
  """
  @spec run(job(), (map(), keyword() -> outcome())) :: outcome()
  def run(%{input: input, opts: opts}, capture \\ &Capture.run/2) do
    capture.(input, opts)
  rescue
    e ->
      {:error,
       Failure.new(:shot_failed, "the capture crashed: #{Exception.message(e)}",
         detail: Exception.message(e)
       )}
  catch
    :exit, reason ->
      {:error, Failure.new(:shot_failed, "the capture exited: #{inspect(reason)}")}
  end

  @doc "Whether a capture failure is the worker's to fix or the infrastructure's."
  @spec classify(Failure.t()) :: :worker | :infrastructure
  def classify(%Failure{code: code}) when code in @worker_codes, do: :worker
  def classify(%Failure{}), do: :infrastructure

  @doc "Route a capture outcome. See the moduledoc table."
  @spec route(outcome()) :: routed()
  def route({:skipped, :no_ui_paths}), do: {:proceed, nil}

  def route({:skipped, {:plan_skip, reason}}) do
    {:proceed,
     "The worker declared a screenshots **skip** for this UI change: #{inspect(reason)}. " <>
       "No screenshots were taken. Judge whether that skip is honest: if the diff changes " <>
       "what a user sees, a lazy skip is a finding."}
  end

  # The capture never boots a change's app unsandboxed (bd-bhrsdv). Not the worker's fault, so not
  # a send-back; not a broken capture either, so no escalation per change: the reviewer judges the
  # diff alone, knowing why.
  def route({:skipped, {:no_sandbox, reason}}) do
    {:proceed,
     "No screenshots were taken: #{reason}. Arbiter only boots a change's app inside a " <>
       "sandbox, and this host cannot provide one; that is the host's setup, not the worker's " <>
       "doing, so do not hold the missing screenshots against the change. Judge the visual " <>
       "result from the diff alone."}
  end

  def route({:ok, result}), do: {:proceed, render_result(result)}

  def route({:error, %Failure{} = failure}) do
    case classify(failure) do
      :worker -> {:send_back, send_back_findings(failure)}
      :infrastructure -> {:escalate, escalation_message(failure)}
    end
  end

  @doc "The reviewer-prompt block for a context from `route/1` (empty when there is none)."
  @spec reviewer_block(String.t() | nil) :: String.t()
  def reviewer_block(nil), do: ""

  def reviewer_block(context) when is_binary(context) do
    "\nUI SCREENSHOTS (this change touches the repo's `ui_paths`): judge the visual result " <>
      "as well as the diff.\n#{context}\n"
  end

  # ── rendering ───────────────────────────────────────────────────────────

  defp render_result(result) do
    rows = Enum.map_join(result.pairs, "\n", &pair_line/1)

    notes =
      case Map.get(result, :notes) do
        n when is_binary(n) and n != "" -> "\nThe worker's notes on the shots: #{n}\n"
        _ -> ""
      end

    "Captured by Arbiter from the running app at the merge-base (before) and the head (after). " <>
      "Open each image file to look at it.\n\n#{rows}\n#{notes}"
  end

  defp pair_line(p) do
    "- #{p.label} (#{p.kind}): before: #{side(p.before)}; after: #{side(p.after)}"
  end

  defp side(%{status: :ok, file: file}), do: file
  defp side(%{status: :absent, reason: reason}), do: reason

  defp send_back_findings(%Failure{code: :manifest_missing}) do
    """
    - **High**: this change touches the repo's UI paths but you gave no screenshots manifest.
      Arbiter looked for `#{@plan_file}` in your worktree and it is not there, so no
      before/after screenshots were captured and a reviewer cannot judge the visual result.
      Add `#{@plan_file}` (it is not committed; it is gitignored scratch) describing what to shoot,
      for example:

          {"version": 1, "shots": [{"id": "my-page", "title": "My page", "path": "/my/page"}]}

      List the pages or states you changed, with declarative steps if a state needs a click. If
      this change genuinely shows nothing different to a user, write
      `{"version": 1, "skip": "<why>"}` instead; the reviewer will judge the reason.
      Do not boot the app or take the screenshots yourself: Arbiter captures them.
      #{no_file_note()}
    """
  end

  defp send_back_findings(%Failure{code: :manifest_invalid} = f) do
    """
    - **High**: your screenshots manifest `#{@plan_file}` does not validate, so no screenshots
      were captured:
    #{error_list(f)}
      Fix the errors above (the file is gitignored scratch and is not committed), keeping it a
      declarative list of shots, or use `{"version": 1, "skip": "<why>"}` if nothing visible changed.
      #{no_file_note()}
    """
  end

  defp send_back_findings(%Failure{} = f) do
    """
    - **High**: the screenshots manifest `#{@plan_file}` names a route that did not render: #{f.message}
      Correct the path (or the `before_path`, if the route moved) in the manifest and keep it a
      declarative list of shots. The file is gitignored scratch and is not committed.
      #{no_file_note()}
    """
  end

  defp error_list(%Failure{detail: errors}) when is_list(errors) and errors != [],
    do: Enum.map_join(errors, "\n", &"      * #{&1}")

  defp error_list(%Failure{message: message}), do: "      * #{message}"

  defp no_file_note do
    "Because the manifest is not committed, your fix moves no commit: print a line starting " <>
      "`#{@no_file_change}` saying what you changed in `#{@plan_file}`, so the gate reads it as " <>
      "done and not as an idle round."
  end

  defp escalation_message(%Failure{} = f) do
    where = if f.role, do: " (at the #{f.role} commit)", else: ""

    "ReviewGate could not capture UI screenshots for this change: #{f.message}#{where}. " <>
      "This is a capture infrastructure failure (#{f.code}), not the worker's: the change was " <>
      "not sent back and no reviewer was dispatched. Check the capture environment (app boot, " <>
      "Chromium, the checkout), then resume the review."
  end
end
