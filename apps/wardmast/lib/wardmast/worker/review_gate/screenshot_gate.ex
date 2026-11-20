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
  | the change edits `mix.lock` (`deps_changed`, bd-3glf2a: the offline deps cache only trusts a default-branch lockfile) | proceeds; the reviewer is told why there are none. Nothing was booted |
  | a **worker fault**: no manifest, an invalid manifest, a named route that errors | sends the change back to the worker with an instruction (`{:send_back, findings}`) |
  | a failure the **change itself caused** (bd-ur1zty): its app does not boot at the head, which the base's did, and not for a service | parks (`{:escalate, message}`: `screenshot_capture_failed`) and does **not** loop the worker |
  | an **infrastructure fault**: the deps cache, a service, the base's own boot, no Chromium, the checkout or diff failed, the budget ran out | **proceeds** (bd-ur1zty): the reviewer's brief says `No screenshots: capture failed: <reason>`; the gate raises one soft `ScreenshotAlert` per repo and cause. A failed capture never fails a merge |

  A repo with no `screenshots` config (or one that does not validate, or a gate with no worktree)
  is `:skip`: the gate behaves exactly as it did before this step existed.

  `plan/2` and `route/1` are pure; `run/2` is what the gate runs in a task, because a capture boots the
  app twice and can take minutes.

  Classification lives in `classify/1`: `:manifest_missing`, `:manifest_invalid` and `:route_error`
  are the worker's (it wrote the plan); a head `:boot_failed` outside the `:services` phase is the
  change's; every other `Wardmast.Screenshots.Capture.Failure` is infrastructure. `:shot_failed` is infrastructure because it cannot tell a bad selector from a
  browser crash, and looping a worker over a crash is the worse mistake.
  """

  alias Wardmast.Mergers
  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Screenshots.Captures
  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.PlanCheck
  alias Wardmast.Tasks.Workspace

  # The line a worker prints to declare a fix with no file change (see ReviewGate's
  # `@non_file_fix_marker`): the plan file is gitignored, so adding it moves no head.
  @no_file_change "NO-FILE-CHANGE:"
  @plan_file ".arbiter/screenshots.json"

  @worker_codes [:manifest_missing, :manifest_invalid, :route_error]

  @type job :: %{
          input: map(),
          config: Config.t(),
          opts: keyword(),
          plan_hash: String.t() | nil,
          config_hash: String.t()
        }
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
  head; `{:run, job}` is a capture to run with `run/2`; `{:reuse, outcome, meta}` keeps the set
  captured at an earlier head instead of taking a new one (see below).

  `history` is `Wardmast.Screenshots.Captures.history/1` (`nil` = no lifecycle rules, the
  pre-bd-8qj1sa behaviour). With it, for a head not yet checked:

    * **cap** — `limits.max_captures_per_ticket` attempts already booted: no new capture. The last
      set is reused (`reason: :cap`) or, with none, the outcome is `{:skipped, {:cap_reached, n}}`;
    * **unchanged** — the diff `last_captured_head..head` misses `ui_paths` and the plan is the one
      that was captured: the last set is reused (`reason: :unchanged`). A changed merge-base alone
      does not re-capture;
    * otherwise a capture runs.

  Reuse needs the previous outcome in `state.screenshot_checked`, so a restarted gate (which lost
  it) captures again rather than reuse something it cannot show the reviewer.
  """
  @spec plan(map(), term(), Captures.history() | nil) ::
          :skip
          | {:cached, outcome()}
          | {:reuse, outcome(), map()}
          | {:run, job()}
  def plan(state, workspace, history \\ nil)

  def plan(%{worktree_path: wt} = state, workspace, history) when is_binary(wt) do
    with {:ok, %Config{} = config} <- Config.resolve(workspace, Map.get(state, :repo)),
         head when is_binary(head) <- Map.get(state, :head_sha),
         base when is_binary(base) <- Map.get(state, :base_sha) do
      case Map.get(state, :screenshot_checked) do
        %{head_sha: ^head, outcome: outcome} ->
          {:cached, outcome}

        checked ->
          lifecycle(state, config, base, head, checked, history, default_branch(workspace, state))
      end
    else
      _ -> :skip
    end
  end

  def plan(_state, _workspace, _history), do: :skip

  defp lifecycle(state, config, base, head, _checked, nil, branch),
    do: {:run, job(state, config, base, head, branch)}

  defp lifecycle(state, config, base, head, checked, history, branch) do
    max = Map.get(config.limits, "max_captures_per_ticket", 3)
    last = history.last_captured

    hashes = %{
      plan_hash: Captures.plan_hash(plan_path(state, state.worktree_path)),
      config_hash: Captures.config_hash(config),
      base_sha: base
    }

    cond do
      history.attempts >= max -> capped(checked, last, max, hashes)
      reusable?(state, config, head, checked, last) -> reuse(checked, last, :unchanged, hashes)
      true -> {:run, job(state, config, base, head, branch)}
    end
  end

  defp capped(%{outcome: {:ok, _}} = checked, %{head_sha: from}, max, hashes),
    do: {:reuse, checked.outcome, Map.merge(hashes, %{reason: :cap, from: from, max: max})}

  defp capped(_checked, _last, max, _hashes), do: {:cached, {:skipped, {:cap_reached, max}}}

  defp reuse(checked, %{head_sha: from}, reason, hashes),
    do: {:reuse, checked.outcome, Map.merge(hashes, %{reason: reason, from: from})}

  # The set to keep must be on hand, be the last captured head's, rest on the plan now in force,
  # and the diff since it must provably miss `ui_paths` (a failing diff re-captures).
  defp reusable?(_state, _config, _head, nil, _last), do: false
  defp reusable?(_state, _config, _head, _checked, nil), do: false

  defp reusable?(state, config, head, %{outcome: {:ok, %{head_sha: from}}}, %{
         head_sha: from,
         plan_hash: plan_hash
       }) do
    plan_hash == Captures.plan_hash(plan_path(state, state.worktree_path)) and
      Config.diff_touches_ui_paths?(config, state.worktree_path, from, head) == {:ok, false}
  end

  defp reusable?(_state, _config, _head, _checked, _last), do: false

  defp job(state, config, base, head, default_branch) do
    wt = state.worktree_path

    out_dir =
      Path.join([System.tmp_dir!(), "arbiter-review-screenshots", state.task_id, head])

    plan_path = plan_path(state, wt)

    %{
      config: config,
      plan_hash: Captures.plan_hash(plan_path),
      config_hash: Captures.config_hash(config),
      input: %{
        task_id: state.task_id,
        repo_path: wt,
        base_sha: base,
        head_sha: head,
        config: config,
        plan_path: plan_path,
        out_dir: out_dir,
        default_branch: default_branch
      },
      opts: Map.get(state, :screenshot_opts, [])
    }
  end

  # bd-3glf2a: the branch whose lockfile the offline deps cache trusts (`merge.base`, else main).
  defp default_branch(workspace, state) do
    ws =
      case workspace do
        %Workspace{} -> workspace
        %{config: %{} = config} -> %Workspace{config: config}
        _ -> nil
      end

    Mergers.base_branch(ws, Map.get(state, :repo)) || "main"
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

  @doc """
  Whose a capture failure is (bd-ur1zty): `:worker` (it wrote the plan), `:change` (the change
  itself broke it: its own app does not boot, at a head whose base did, and not for a service)
  or `:infrastructure` (anything else: the deps cache, a service, a checkout, the browser, the
  budget, the base's own boot).
  """
  @spec classify(Failure.t()) :: :worker | :change | :infrastructure
  def classify(%Failure{code: code}) when code in @worker_codes, do: :worker

  # Captures boot the base first and stop at the first failure, so a head that fails to boot has a
  # base that booted. A service that did not come up is the host's (podman, the image), whichever
  # commit it was booting for.
  def classify(%Failure{code: :boot_failed, role: "after", detail: %{phase: phase}})
      when phase != :services,
      do: :change

  def classify(%Failure{}), do: :infrastructure

  @doc """
  The infrastructure failure in a capture outcome, for the gate to alert on: `{:ok, failure}`, or
  `:none` for an outcome that is not one (a success, a skip, a worker's or the change's own fault).
  """
  @spec infrastructure_failure(outcome()) :: {:ok, Failure.t()} | :none
  def infrastructure_failure({:error, %Failure{} = failure}) do
    if classify(failure) == :infrastructure, do: {:ok, failure}, else: :none
  end

  def infrastructure_failure(_outcome), do: :none

  @doc """
  Route a capture outcome. See the moduledoc table.

  `opts[:health]` is `Wardmast.Screenshots.Captures.health/1` (default `:unknown`). While it is
  `:failing` (bd-5eegxz) a missing or invalid manifest is not sent back: no fix round is spent on
  a manifest for a capture that keeps failing or skipping for reasons the worker cannot fix; the
  reviewer is told instead. A route the manifest names that errors is still the worker's (both
  apps booted).
  """
  @spec route(outcome(), keyword()) :: routed()
  def route(outcome, opts \\ [])

  def route({:skipped, :no_ui_paths}, _opts), do: {:proceed, nil}

  def route({:skipped, {:plan_skip, reason}}, _opts) do
    {:proceed,
     "The worker declared a screenshots **skip** for this UI change: #{inspect(reason)}. " <>
       "No screenshots were taken. Judge whether that skip is honest: if the diff changes " <>
       "what a user sees, a lazy skip is a finding."}
  end

  # The capture never boots a change's app unsandboxed (bd-bhrsdv). Not the worker's fault, so not
  # a send-back; not a broken capture either, so no escalation per change: the reviewer judges the
  # diff alone, knowing why.
  def route({:skipped, {:no_sandbox, reason}}, _opts) do
    {:proceed,
     "No screenshots were taken: #{reason}. Arbiter only boots a change's app inside a " <>
       "sandbox, and this host cannot provide one; that is the host's setup, not the worker's " <>
       "doing, so do not hold the missing screenshots against the change. Judge the visual " <>
       "result from the diff alone."}
  end

  # bd-3glf2a: the boot has no network, and its Mix deps come only from a lockfile the default
  # branch has had. A dependency change is legitimate work, so not a send-back; nothing is broken
  # either, so no escalation: the reviewer judges the diff, knowing why there are no pictures.
  def route({:skipped, {:deps_changed, reason}}, _opts) do
    {:proceed,
     "No screenshots were taken: #{reason}. This is expected for a change to the project's " <>
       "dependencies (mix.lock), not the worker's fault, so do not hold the missing screenshots " <>
       "against the change. Judge the visual result from the diff alone."}
  end

  # bd-8qj1sa: `limits.max_captures_per_ticket` attempts were already spent and none produced a
  # set. Not the worker's fault, so no send-back; the reviewer judges the diff alone, knowing why.
  def route({:skipped, {:cap_reached, max}}, _opts) do
    {:proceed,
     "No screenshots were taken for this head: the ticket already used its " <>
       "`max_captures_per_ticket` (#{max}) capture attempts. Judge the visual result from the " <>
       "diff alone."}
  end

  def route({:ok, result}, _opts), do: {:proceed, render_result(result)}

  def route({:error, %Failure{} = failure}, opts) do
    case classify(failure) do
      :worker -> route_worker_fault(failure, Keyword.get(opts, :health, :unknown))
      :change -> {:escalate, escalation_message(failure)}
      :infrastructure -> {:proceed, infrastructure_brief(failure)}
    end
  end

  defp route_worker_fault(%Failure{code: code} = failure, :failing)
       when code in [:manifest_missing, :manifest_invalid] do
    {:proceed,
     "No screenshots were taken: #{failure.message}. Captures for this workspace have been " <>
       "failing or skipping for reasons that are not the worker's (the app does not boot at " <>
       "the merge-base in the capture sandbox, or the change edits mix.lock), so the manifest " <>
       "was not sent back for a fix and the missing screenshots are not the worker's doing. " <>
       "Judge the visual result from the diff alone."}
  end

  defp route_worker_fault(failure, _health), do: {:send_back, send_back_findings(failure)}

  @doc """
  Route a set kept from an earlier head (`plan/3`'s `{:reuse, outcome, meta}`): `route/1`'s answer
  with a line saying which commit the screenshots were taken at, so a reviewer is never shown a
  stale set as if it were the head's.
  """
  @spec route_reuse(outcome(), map(), String.t(), keyword()) :: routed()
  def route_reuse(outcome, %{reason: reason, from: from} = meta, head, opts \\ []) do
    case route(outcome, opts) do
      {:proceed, context} when is_binary(context) ->
        {:proceed, reuse_note(reason, meta, from, head) <> context}

      other ->
        other
    end
  end

  defp reuse_note(:unchanged, _meta, from, head),
    do:
      "These screenshots were taken at #{String.slice(from, 0, 12)}; the head is now " <>
        "#{String.slice(head, 0, 12)}, but nothing under `ui_paths` changed since and the plan " <>
        "is the same, so they were not retaken.\n\n"

  defp reuse_note(:cap, meta, from, head),
    do:
      "These screenshots were taken at #{String.slice(from, 0, 12)}, NOT at the head " <>
        "#{String.slice(head, 0, 12)}: the ticket reached its `max_captures_per_ticket` " <>
        "(#{Map.get(meta, :max)}) so the head was not captured. The UI may differ.\n\n"

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
      "The app booted at the merge-base (the base booted) and not at the head, so the change " <>
      "itself is the likely cause (#{f.code}): it was not sent back and no reviewer was " <>
      "dispatched. Check whether the head's app boots (a config, migration or dependency the " <>
      "change broke, or a flake), then resume the review."
  end

  # bd-ur1zty: the failure is the capture environment's, not the change's and not the worker's,
  # so the review goes ahead on the diff alone, told why (and the soft attention says it once).
  defp infrastructure_brief(%Failure{} = f) do
    where = if f.role, do: " (at the #{f.role} commit)", else: ""

    "No screenshots: capture failed: #{f.message}#{where}. This is a capture-infrastructure " <>
      "failure (#{f.code}), not the worker's doing, so do not hold the missing screenshots " <>
      "against the change. Judge the visual result from the diff alone."
  end
end
