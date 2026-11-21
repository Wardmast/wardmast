defmodule Wardmast.Screenshots.PlanCheck do
  @moduledoc """
  Early check of the worker's screenshots plan (`.arbiter/screenshots.json`), shared by the
  `arb done` commit gate, `ward screenshots check` and the `screenshots_plan_check` MCP tool.

  `check/4` answers, for a worktree and the branch it targets: does the diff touch `ui_paths`
  and, if so, is there a plan that validates (a `skip` counts)? A missing or invalid plan is
  `{:error, [message]}` so the worker hears about it at `arb done` instead of in a ReviewGate
  revise round. `plan_required: false` lets a missing plan pass (capture then falls back to
  `default_routes`, see `default_plan/1`).

  A passing check yields the plan's `sha` (sha256 of the file bytes) and `body`. The gate stores
  both outside the worktree (`store/3`) so the capture shoots exactly what was checked, not
  whatever the worker edits afterwards. `exclude_plan/1` keeps the plan out of `git status` via
  `.git/info/exclude`.
  """

  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.Plan

  @plan_file ".arbiter/screenshots.json"

  @type checked :: %{sha: String.t() | nil, body: String.t() | nil, skip: String.t() | nil}

  @doc "The plan's path relative to the worktree."
  @spec plan_file() :: String.t()
  def plan_file, do: @plan_file

  @spec check(Config.t(), String.t(), String.t() | nil, keyword()) ::
          :not_applicable | {:ok, checked()} | {:error, [String.t()]}
  def check(%Config{} = config, worktree, target, _opts \\ []) do
    with true <- is_binary(target) and target != "",
         {:ok, base} <- merge_base(config, worktree, target),
         {:ok, true} <- Config.diff_touches_ui_paths?(config, worktree, base, "HEAD") do
      read(config, Path.join(worktree, @plan_file))
    else
      {:halt, result} -> result
      _ -> :not_applicable
    end
  end

  # Same base resolution as ReviewGate (`origin/<target>` first): a stale local branch would
  # diff in upstream commits. With plan_required an unresolvable base fails closed.
  defp merge_base(config, worktree, target) do
    case Wardmast.Worker.Worktree.merge_base(worktree, target) do
      sha when is_binary(sha) -> {:ok, sha}
      _ when config.plan_required == true -> {:halt, {:error, [unresolved(target)]}}
      _ -> :error
    end
  end

  defp unresolved(target),
    do: "could not resolve the merge base against #{target}; cannot check #{@plan_file}"

  defp read(config, path) do
    case File.read(path) do
      {:ok, body} ->
        case Plan.parse(body, config) do
          {:ok, plan} ->
            {:ok, %{sha: sha(body), body: body, skip: plan.skip}}

          {:error, {:invalid, errors}} ->
            {:error, ["#{@plan_file} is invalid:" | Enum.map(errors, &"  * #{&1}")]}
        end

      {:error, :enoent} when config.plan_required == false ->
        {:ok, %{sha: nil, body: nil, skip: nil}}

      {:error, :enoent} ->
        {:error,
         [
           "This change touches the UI (ui_paths) but #{@plan_file} is missing. Write it " <>
             "(`version: 1` with `shots`, or a `skip` reason) and run `ward screenshots check`."
         ]}

      {:error, reason} ->
        {:error, ["could not read #{@plan_file}: #{:file.format_error(reason)}"]}
    end
  end

  @doc "sha256 (lowercase hex) of the plan bytes."
  @spec sha(binary()) :: String.t()
  def sha(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  @doc """
  The plan implied by `default_routes` when `plan_required` is false and the worker wrote none:
  one shot per route, or `nil` when there are no routes.
  """
  @spec default_plan(Config.t()) :: {:ok, Plan.t()} | nil
  def default_plan(%Config{plan_required: false, default_routes: [_ | _] = routes} = config) do
    shots =
      routes
      |> Enum.with_index(1)
      |> Enum.map(fn {path, i} -> %{"id" => "route-#{i}", "path" => path} end)

    body = Jason.encode!(%{"version" => 1, "shots" => shots})

    case Plan.parse(body, config) do
      {:ok, plan} -> {:ok, plan}
      _ -> nil
    end
  end

  def default_plan(_config), do: nil

  # ── stored copy ─────────────────────────────────────────────────────────

  @doc "Where the checked copy of `task_id`'s plan lives under `root`."
  @spec stored_path(String.t(), String.t()) :: String.t()
  def stored_path(root, task_id), do: Path.join([root, task_id, "plan.json"])

  @doc "Store the checked plan (and its sha). A check with no plan removes any older copy."
  @spec store(String.t(), String.t(), checked()) :: :ok
  def store(root, task_id, %{body: body, sha: sha}) when is_binary(body) do
    path = stored_path(root, task_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.write!(path <> ".sha256", sha)
    :ok
  end

  def store(root, task_id, _none) do
    path = stored_path(root, task_id)
    File.rm(path)
    File.rm(path <> ".sha256")
    :ok
  end

  @doc "The sha recorded for the stored copy, if its bytes still match."
  @spec stored_sha(String.t(), String.t()) :: {:ok, String.t()} | :error
  def stored_sha(root, task_id) do
    path = stored_path(root, task_id)

    with {:ok, body} <- File.read(path),
         {:ok, sha} <- File.read(path <> ".sha256"),
         true <- sha(body) == sha do
      {:ok, sha}
    else
      _ -> :error
    end
  end

  @doc "Where the gate keeps checked plans (outside every worktree)."
  @spec store_root() :: String.t()
  def store_root, do: Path.join(System.tmp_dir!(), "arbiter-screenshot-plans")

  @doc """
  The commit-gate step for `arb done`: `nil` when the screenshots gate does not apply, else
  `%{step:, plan:}` where `step` is a `Wardmast.Worker.PrepushCheck.step_result` (`:passed` or
  `:failed`) and `plan` is the checked plan (also stored under `store_root/0`, with the plan
  excluded from git) or `nil`.
  """
  @spec gate(Config.t(), String.t(), String.t() | nil, String.t()) :: nil | map()
  def gate(%Config{} = config, worktree, target, task_id) do
    started = System.monotonic_time(:millisecond)
    exclude_plan(worktree)
    strip_committed(worktree, target)

    case check(config, worktree, target) do
      :not_applicable ->
        nil

      {:ok, checked} ->
        store(store_root(), task_id, checked)
        %{step: step(:passed, 0, passed_text(checked), started), plan: checked}

      {:error, messages} ->
        %{step: step(:failed, 1, Enum.join(messages, "\n"), started), plan: nil}
    end
  end

  defp passed_text(%{sha: nil}), do: "no plan (plan_required is false); default_routes apply"
  defp passed_text(%{skip: s}) when is_binary(s), do: "valid skip: #{s}"
  defp passed_text(%{sha: sha}), do: "plan valid (sha256 #{String.slice(sha, 0, 12)})"

  defp step(status, exit_status, output, started) do
    %{
      name: "screenshots plan",
      cmd: "ward screenshots check",
      scope: :all,
      status: status,
      exit_status: exit_status,
      duration_ms: max(System.monotonic_time(:millisecond) - started, 0),
      limit_s: nil,
      output: output,
      full_output: nil,
      reason: nil
    }
  end

  @doc """
  Fold a `gate/4` outcome into a `PrepushCheck.run_steps` result: the step is appended and a red
  one turns an otherwise passing (or fail-open) result into `{:failed, 1, output}`. The checked
  plan's sha rides along as `:screenshots_plan`.
  """
  @spec merge_gate(map(), nil | map()) :: map()
  def merge_gate(run, nil), do: run

  def merge_gate(%{result: result, steps: steps} = run, %{step: step, plan: plan}) do
    result =
      case {step.status, result} do
        {:failed, {:failed, _, _}} -> result
        {:failed, _} -> {:failed, step.exit_status, step.output}
        _ -> result
      end

    run
    |> Map.merge(%{result: result, steps: steps ++ [step]})
    |> Map.put(:screenshots_plan, plan && Map.take(plan, [:sha, :skip]))
  end

  @doc """
  Commit-gate guard: the manifest is per-change review metadata and must never reach the target
  branch (two committed copies on main made every other branch conflict on it). If the branch
  tracks it and the merge base does not, drop it from the index and commit the removal (the
  working-tree file stays, so the checked copy is still shot). A manifest the target already
  carries is left alone: deleting it is the operator's one-time cleanup.
  """
  @spec strip_committed(String.t(), String.t() | nil) :: :stripped | :clean
  def strip_committed(worktree, target) do
    base =
      if is_binary(target) and target != "",
        do: Wardmast.Worker.Worktree.merge_base(worktree, target)

    with true <- git_ok?(worktree, ["cat-file", "-e", "HEAD:" <> @plan_file]),
         false <-
           is_binary(base) and git_ok?(worktree, ["cat-file", "-e", base <> ":" <> @plan_file]),
         true <- git_ok?(worktree, ["rm", "--cached", "-q", "--", @plan_file]),
         true <-
           git_ok?(worktree, [
             "-c",
             "user.name=arbiter",
             "-c",
             "user.email=arbiter@localhost",
             "commit",
             "-q",
             "-m",
             "Remove per-run screenshots manifest (never committed)"
           ]) do
      :stripped
    else
      _ -> :clean
    end
  end

  defp git_ok?(dir, args),
    do: match?({_, 0}, System.cmd("git", args, cd: dir, stderr_to_stdout: true))

  @doc "Add the plan file to the repo's `info/exclude` (idempotent; worktree-aware)."
  @spec exclude_plan(String.t()) :: :ok
  def exclude_plan(worktree) do
    case System.cmd("git", ["rev-parse", "--git-path", "info/exclude"],
           cd: worktree,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        path = out |> String.trim() |> Path.expand(worktree)
        current = File.read(path) |> elem_or("")

        unless String.contains?(current, @plan_file) do
          File.mkdir_p!(Path.dirname(path))
          sep = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
          File.write!(path, current <> sep <> @plan_file <> "\n")
        end

        :ok

      _ ->
        :ok
    end
  end

  defp elem_or({:ok, v}, _), do: v
  defp elem_or(_, default), do: default
end
