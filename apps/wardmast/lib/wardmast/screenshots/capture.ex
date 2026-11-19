defmodule Wardmast.Screenshots.Capture do
  @moduledoc """
  The capture step: boot the app at the merge-base and at the head and shoot every route the
  worker declared, then pair the images (`docs/design/ui-screenshot-capture.md` §4, §5).

  It is deterministic orchestration with no agent turn. `run/2` does, in order:

  1. **Gate.** If the diff `base..head` does not touch `ui_paths`, return
     `{:skipped, :no_ui_paths}` having read, booted and written nothing.
  2. **Sandbox.** Everything booted from here on is the repo's code at a commit a worker wrote, so
     it runs only inside a `Wardmast.Screenshots.Capture.Sandbox` (default `Sandbox.Bwrap`: no
     network, no host loopback, no host files beyond the system directories). A host that cannot
     provide it is `{:skipped, {:no_sandbox, reason}}` ("capture needs a sandbox: ..."), before
     the plan is read or anything runs. A capture is never run unsandboxed.
  3. **Plan.** Read the worker's `.arbiter/screenshots.json` (`Wardmast.Screenshots.Plan`). A plan
     that is `skip` is `{:skipped, {:plan_skip, reason}}`.
  4. **Two boots, one after the other.** Extract the base tree with `git archive`, boot it via the
     `Booter`, shoot every entry with the `Shooter`, stop it; then the same for the head. A route
     that answers 404 is *absent* at that commit, not an error. Both get the sandbox; each shot
     also gets a fresh directory of its own (`scratch`), so a browser never writes beside the
     images other shots produced.
  5. **Pairs.** present at both is `:changed`; absent at the base is `:new` (after-only); absent at
     the head is `:removed` (before-only); absent at both is a route error.

  Every failure is a `Wardmast.Screenshots.Capture.Failure` with a distinct `code`
  (`:manifest_missing`, `:manifest_invalid`, `:boot_failed`, `:route_error`, ...). Success, skip and
  failure are all recorded in `<out_dir>/capture.json` (once the step has begun) and handed to
  `opts[:record]`, so the ReviewGate reads a reason rather than silence. The first failure stops the
  pass: a base route error never boots the head.

  `poster_pairs/1` converts a result into the pairs `Wardmast.Screenshots.Poster.post/4` takes.

  ## Input

  `%{task_id:, repo_path:, base_sha:, head_sha:, config:, plan_path:, out_dir:}` where `repo_path`
  is a git checkout that has both commits and `base_sha` is the merge-base.

  ## Options

  `:booter` (default `Booter.Command`), `:shooter` (default `Shooter.Chromium`), `:sandbox`
  (default `Sandbox.default/0`, the bwrap sandbox; passed to both), `:ctx` (passed to both),
  `:record` (`(map -> any)`), `:budget_seconds` (default `limits.budget_seconds`; checked
  before every boot and shot, on top of the booter's own per-phase timeouts).
  """

  require Logger

  alias Wardmast.Screenshots.Capture.Booter
  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Screenshots.Capture.Shooter
  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.Plan
  alias Wardmast.Screenshots.PlanCheck
  alias Wardmast.Worker.ReleaseEnv

  @type side ::
          %{
            status: :ok,
            file: String.t(),
            name: String.t(),
            sha256: String.t(),
            bytes: non_neg_integer()
          }
          | %{status: :absent, reason: String.t()}
  @type pair :: %{
          id: String.t(),
          title: String.t(),
          viewport: String.t(),
          theme: String.t(),
          label: String.t(),
          kind: :changed | :new | :removed,
          before: side(),
          after: side()
        }
  @type result :: %{
          task_id: String.t(),
          base_sha: String.t(),
          head_sha: String.t(),
          pairs: [pair()],
          boots: [map()],
          notes: String.t() | nil,
          out_dir: String.t(),
          manifest_path: String.t()
        }

  @type run_outcome ::
          {:ok, result()}
          | {:skipped, :no_ui_paths | {:plan_skip, String.t()} | {:no_sandbox, String.t()}}
          | {:error, Failure.t()}

  @doc "Run the capture step. See the moduledoc."
  @spec run(map(), keyword()) :: run_outcome()
  def run(%{config: %Config{} = config} = input, opts \\ []) do
    case Config.diff_touches_ui_paths?(config, input.repo_path, input.base_sha, input.head_sha) do
      {:ok, false} ->
        {:skipped, :no_ui_paths}

      {:ok, true} ->
        input |> begin(opts) |> capture() |> finish()

      {:error, msg} ->
        input |> begin(opts) |> fail(Failure.new(:diff_failed, "git diff failed: #{msg}"))
    end
  end

  defp begin(input, opts) do
    File.mkdir_p!(input.out_dir)
    config = input.config
    budget = Keyword.get(opts, :budget_seconds, Map.get(config.limits, "budget_seconds", 1200))

    %{
      input: input,
      booter: Keyword.get(opts, :booter, Booter.Command),
      shooter: Keyword.get(opts, :shooter, Shooter.Chromium),
      sandbox: Keyword.get(opts, :sandbox) || Sandbox.default(),
      ctx: Keyword.get(opts, :ctx),
      record: Keyword.get(opts, :record),
      budget: budget,
      deadline: System.monotonic_time(:millisecond) + budget * 1000,
      images: Path.join(input.out_dir, "images")
    }
  end

  defp capture(%{input: input} = st) do
    with :ok <- sandboxed(st),
         {:ok, plan} <- read_plan(st),
         :ok <- not_skipped(plan),
         {:ok, before_run} <- run_role(st, "before", input.base_sha, plan.shots),
         {:ok, after_run} <- run_role(st, "after", input.head_sha, plan.shots),
         {:ok, pairs} <- pair(plan.shots, before_run.outcomes, after_run.outcomes) do
      {:ok, st, plan, pairs, [before_run.boot, after_run.boot]}
    else
      {:skip, kind, reason} -> {:skip, st, kind, reason}
      {:error, %Failure{} = failure} -> {:error, st, failure}
    end
  end

  # Fail closed: no sandbox, no boot.
  defp sandboxed(st) do
    case Sandbox.check(st.sandbox) do
      :ok -> :ok
      {:error, reason} -> {:skip, :no_sandbox, reason}
    end
  end

  defp finish({:ok, st, plan, pairs, boots}) do
    result = %{
      task_id: st.input.task_id,
      base_sha: st.input.base_sha,
      head_sha: st.input.head_sha,
      pairs: pairs,
      boots: boots,
      notes: plan.notes,
      out_dir: st.input.out_dir,
      manifest_path: manifest_path(st)
    }

    record(st, %{state: :ok, result: result}, manifest(st, "ok", result: result))
    {:ok, result}
  end

  defp finish({:skip, st, kind, reason}) do
    if kind == :no_sandbox,
      do: Logger.warning("Screenshots.Capture #{st.input.task_id}: skipped: #{reason}")

    record(
      st,
      %{state: :skipped, kind: kind, reason: reason},
      manifest(st, "skipped", skip: {kind, reason})
    )

    {:skipped, {kind, reason}}
  end

  defp finish({:error, st, failure}), do: fail(st, failure)

  defp fail(st, failure) do
    Logger.warning("Screenshots.Capture #{st.input.task_id}: #{failure.code}: #{failure.message}")

    record(st, %{state: :failed, failure: failure}, manifest(st, "failed", failure: failure))
    {:error, failure}
  end

  # ── plan ────────────────────────────────────────────────────────────────

  defp read_plan(%{input: input}) do
    case Plan.read(input.plan_path, input.config) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, :missing} ->
        case PlanCheck.default_plan(input.config) do
          {:ok, plan} -> {:ok, plan}
          nil -> missing_plan(input)
        end

      {:error, {:invalid, errors}} ->
        {:error,
         Failure.new(
           :manifest_invalid,
           "the screenshots manifest is invalid: #{Enum.join(errors, "; ")}",
           detail: errors
         )}
    end
  end

  defp missing_plan(input) do
    {:error,
     Failure.new(
       :manifest_missing,
       "the worker wrote no screenshots manifest (.arbiter/screenshots.json), so there is " <>
         "nothing to capture",
       detail: input.plan_path
     )}
  end

  defp not_skipped(%Plan{skip: nil}), do: :ok
  defp not_skipped(%Plan{skip: reason}), do: {:skip, :plan_skip, reason}

  # ── one role: extract, boot, shoot every entry, stop ────────────────────

  defp run_role(st, role, sha, entries) do
    work = Path.join([st.input.out_dir, "work", role])
    checkout = Path.join(work, "checkout")
    started = System.monotonic_time(:millisecond)

    try do
      with :ok <- check_budget(st),
           :ok <- extract(st.input.repo_path, sha, checkout, role),
           {:ok, outcomes} <- shoot_groups(st, role, entries, work, checkout) do
        boot = %{
          "role" => role,
          "status" => "ok",
          "duration_ms" => System.monotonic_time(:millisecond) - started
        }

        {:ok, %{outcomes: outcomes, boot: boot}}
      end
    after
      File.rm_rf(work)
    end
  end

  defp extract(repo, sha, checkout, role) do
    tar = checkout <> ".tar"
    File.mkdir_p!(checkout)

    with {_, 0} <-
           System.cmd("git", ["-C", repo, "archive", "--format=tar", "-o", tar, sha],
             stderr_to_stdout: true
           ),
         {_, 0} <- ReleaseEnv.cmd("tar", ["-xf", tar, "-C", checkout], stderr_to_stdout: true) do
      File.rm(tar)
      :ok
    else
      {out, _} ->
        {:error,
         Failure.new(
           :checkout_failed,
           "could not extract #{String.slice(sha, 0, 12)}: #{String.trim(out)}",
           role: role
         )}
    end
  end

  # Entries that need a named seed boot separately: one boot per seed, default seed first.
  defp shoot_groups(st, role, entries, work, checkout) do
    entries
    |> Enum.group_by(& &1.seed)
    |> Enum.sort_by(fn {seed, _} -> seed || "" end)
    |> Enum.reduce_while({:ok, %{}}, fn {seed, group}, {:ok, acc} ->
      with :ok <- check_budget(st),
           {:ok, outcomes} <- boot_and_shoot(st, role, seed, group, work, checkout) do
        {:cont, {:ok, Map.merge(acc, outcomes)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp boot_and_shoot(st, role, seed, group, work, checkout) do
    scratch = Path.join(work, "scratch-#{seed || "default"}")
    File.mkdir_p!(scratch)

    spec = %{
      role: role,
      checkout: checkout,
      scratch: scratch,
      seed: seed,
      config: st.input.config,
      task_id: st.input.task_id,
      sandbox: st.sandbox,
      ctx: st.ctx
    }

    case boot(st, spec) do
      {:ok, %{handle: handle, base_url: base_url} = booted} ->
        # `app` is how the sandbox reaches the booted app; the shooter needs it to give the
        # browser its (only) way there.
        target = %{
          base_url: base_url,
          app: Map.get(booted, :app),
          shots: Path.join(work, "shots")
        }

        try do
          shoot_all(st, spec, target, group)
        after
          safe_stop(st, spec, handle)
        end

      {:error, {phase, detail}} ->
        {:error,
         Failure.new(
           :boot_failed,
           "the app failed to boot at the #{describe_role(role)} (#{phase}): #{detail_text(detail)}",
           role: role,
           detail: %{phase: phase, output: detail_text(detail)}
         )}
    end
  end

  defp boot(st, spec) do
    st.booter.boot(spec)
  rescue
    e -> {:error, {:start, Exception.message(e)}}
  end

  defp safe_stop(st, spec, handle) do
    st.booter.stop(spec, handle)
  rescue
    e -> Logger.warning("Screenshots.Capture: stopping the app failed: #{Exception.message(e)}")
  end

  defp shoot_all(st, spec, target, group) do
    Enum.reduce_while(group, {:ok, %{}}, fn entry, {:ok, acc} ->
      with :ok <- check_budget(st),
           {:ok, outcome} <- shoot_one(st, spec, target, entry) do
        {:cont, {:ok, Map.put(acc, key(entry), outcome)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp shoot_one(st, spec, target, entry) do
    role = spec.role
    path = if role == "before", do: entry.before_path || entry.path, else: entry.path
    name = "#{entry.id}__#{entry.viewport}-#{entry.theme}__#{role}.png"
    File.mkdir_p!(st.images)
    out_file = Path.join(st.images, name)
    cfg = st.input.config
    # The shot's own directory: the only place its browser may write (never `images/`, where the
    # other shots' pictures are, and never the app's checkout or scratch).
    scratch = Path.join(target.shots, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(scratch)

    shot = %{
      role: role,
      base_url: target.base_url,
      path: path,
      entry: entry,
      out_file: out_file,
      config: cfg,
      viewport: Map.fetch!(cfg.viewports, entry.viewport),
      theme: Map.fetch!(cfg.themes, entry.theme),
      timeout_s: Map.get(cfg.limits, "shot_seconds", 30),
      sandbox: st.sandbox,
      app: target.app,
      scratch: scratch,
      ctx: st.ctx
    }

    try do
      case call_shooter(st.shooter, shot) do
        :ok -> image(out_file, name, role, entry)
        {:error, {:http_status, 404}} -> {:ok, :absent}
        {:error, reason} -> {:error, shot_failure(reason, role, entry, path)}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp call_shooter(shooter, shot) do
    shooter.shoot(shot)
  rescue
    e -> {:error, {:shot, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:shot, "exited: #{inspect(reason)}"}}
  end

  defp image(file, name, role, entry) do
    case File.read(file) do
      {:ok, data} when data != "" ->
        {:ok,
         {:ok,
          %{
            status: :ok,
            file: file,
            name: name,
            sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
            bytes: byte_size(data)
          }}}

      _ ->
        {:error,
         Failure.new(
           :shot_failed,
           "#{entry.id}: the browser wrote no image at the #{describe_role(role)}",
           role: role,
           shot: entry.id
         )}
    end
  end

  defp shot_failure({:http_status, status}, role, entry, path) do
    Failure.new(
      :route_error,
      "#{entry.id}: GET #{path} answered #{status} at the #{describe_role(role)}",
      role: role,
      shot: entry.id,
      detail: %{path: path, status: status}
    )
  end

  defp shot_failure({:shot, detail}, role, entry, _path) do
    Failure.new(:shot_failed, "#{entry.id}: #{detail_text(detail)}",
      role: role,
      shot: entry.id,
      detail: detail_text(detail)
    )
  end

  defp shot_failure(other, role, entry, path),
    do: shot_failure({:shot, inspect(other)}, role, entry, path)

  # ── pairing ─────────────────────────────────────────────────────────────

  defp pair(entries, before_outcomes, after_outcomes) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case pair_one(
             entry,
             Map.fetch!(before_outcomes, key(entry)),
             Map.fetch!(after_outcomes, key(entry))
           ) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp pair_one(entry, {:ok, before_img}, {:ok, after_img}),
    do: {:ok, build_pair(entry, :changed, before_img, after_img)}

  defp pair_one(entry, :absent, {:ok, after_img}),
    do:
      {:ok, build_pair(entry, :new, %{status: :absent, reason: "new at this commit"}, after_img)}

  defp pair_one(entry, {:ok, before_img}, :absent),
    do:
      {:ok,
       build_pair(entry, :removed, before_img, %{
         status: :absent,
         reason: "removed at this commit"
       })}

  defp pair_one(entry, :absent, :absent) do
    {:error,
     Failure.new(
       :route_error,
       "#{entry.id}: #{entry.path} answered 404 at both the merge-base and the head",
       role: "after",
       shot: entry.id,
       detail: %{path: entry.path, status: 404}
     )}
  end

  defp build_pair(entry, kind, before_side, after_side) do
    %{
      id: entry.id,
      title: entry.title,
      viewport: entry.viewport,
      theme: entry.theme,
      label: "#{entry.title} · #{entry.viewport} · #{entry.theme}",
      kind: kind,
      before: before_side,
      after: after_side
    }
  end

  defp key(entry), do: {entry.id, entry.viewport, entry.theme}

  @doc """
  The pairs of `result` in the shape `Wardmast.Screenshots.Poster.post/4` takes: images are read
  from disk, an absent side becomes its reason text.
  """
  @spec poster_pairs(result()) :: [map()]
  def poster_pairs(%{pairs: pairs}) do
    Enum.map(pairs, fn p ->
      %{label: p.label, before: poster_side(p.before), after: poster_side(p.after)}
    end)
  end

  defp poster_side(%{status: :ok, name: name, file: file}),
    do: %{name: name, data: File.read!(file)}

  defp poster_side(%{status: :absent, reason: reason}), do: {:text, reason}

  # ── budget and recording ────────────────────────────────────────────────

  defp check_budget(%{deadline: deadline, budget: budget}) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error,
       Failure.new(
         :budget_exceeded,
         "the capture ran out of its #{budget} s budget"
       )}
    else
      :ok
    end
  end

  defp manifest_path(st), do: Path.join(st.input.out_dir, "capture.json")

  defp manifest(st, state, extra) do
    input = st.input

    base = %{
      "version" => 1,
      "state" => state,
      "task_id" => input.task_id,
      "head_sha" => input.head_sha,
      "base_sha" => input.base_sha
    }

    Enum.reduce(extra, base, fn
      {:failure, f}, acc ->
        Map.put(acc, "failure", Failure.to_map(f))

      {:skip, {kind, reason}}, acc ->
        Map.merge(acc, %{"skip" => reason, "skip_kind" => "#{kind}"})

      {:result, r}, acc ->
        Map.merge(acc, result_json(r))
    end)
  end

  defp result_json(result) do
    %{
      "boots" => result.boots,
      "notes" => result.notes,
      "shots" => Enum.map(result.pairs, &pair_json/1)
    }
  end

  defp pair_json(p) do
    %{
      "id" => p.id,
      "viewport" => p.viewport,
      "theme" => p.theme,
      "kind" => Atom.to_string(p.kind),
      "before" => side_json(p.before),
      "after" => side_json(p.after)
    }
  end

  defp side_json(%{status: :ok} = s),
    do: %{
      "status" => "ok",
      "file" => Path.basename(s.file),
      "sha256" => s.sha256,
      "bytes" => s.bytes
    }

  defp side_json(%{status: :absent, reason: reason}),
    do: %{"status" => "absent", "reason" => reason}

  defp record(st, event, manifest) do
    File.write!(manifest_path(st), Jason.encode!(manifest, pretty: true))

    case st.record do
      fun when is_function(fun, 1) -> fun.(event)
      _ -> :ok
    end
  end

  defp describe_role("before"), do: "merge-base"
  defp describe_role("after"), do: "head"

  defp detail_text(text) when is_binary(text), do: text
  defp detail_text(other), do: inspect(other)
end
