defmodule Wardmast.Worker.VisualBaselines do
  @moduledoc """
  The deterministic visual-baseline refresh (bd-9obzu9, GitHub #936).

  Several UI branches change the same pages, so every merge to main makes the
  other open branches' reference screenshots stale and their `visual` job fails.
  Fixing that is mechanical: download the job's actual images and copy them over
  the baselines. This module does it without an agent, for exactly the case where
  that is safe, and never otherwise.

  `refresh/1` runs when a head's CI is red (the Watchdog's `:ci_failed` path calls
  it before dispatching a fix pass) and the repo has a
  `worker.repos.<repo>.visual_baselines` block (`Config`). It refreshes only when

    1. the configured visual job is the **only** failed job of the head's pipeline
       and the artifacts belong to that exact head (`ci_job_artifacts/3`);
    2. the failure is main's drift, not the branch's own work (`Drift.decide/5`,
       against the last commit whose visual job was green, `last_green_job_sha/3`);
    3. every actual image maps to exactly one existing baseline (`Archive.plan/3`).

  Then, in a throwaway checkout of the branch (never the shared one), it overwrites
  those baseline files only, commits "Refresh visual baselines after syncing main (auto)"
  and pushes a plain, non-forced push with the repo's host credential. Anything
  else returns `{:skip, reason}` and the failure takes the normal fix path.

  The push is an authored push like a CI fix pass's: the caller records it as one
  (`Watchdog.note_authored_push/1`), so the new head — with its image diff — goes
  back through the ReviewGate before the PR can merge.

  The adapter supplies two optional `Wardmast.Mergers.Merger` callbacks,
  `ci_job_artifacts/3` and `last_green_job_sha/3`.
  """

  require Logger

  alias Wardmast.Mergers.LocalCompare
  alias Wardmast.Reviews.Checkout
  alias Wardmast.Worker.HostCredential
  alias Wardmast.Worker.VisualBaselines.{Archive, Config, Drift}

  @type ctx :: %{
          required(:workspace) => term(),
          required(:repo) => String.t() | nil,
          required(:adapter) => module(),
          required(:mr_ref) => String.t(),
          required(:result) => map()
        }

  @type outcome ::
          {:refreshed, %{sha: String.t(), files: [String.t()]}}
          | {:skip, term()}
          | {:error, term()}

  @doc "The subject of the commit this makes."
  @spec commit_subject() :: String.t()
  def commit_subject, do: Drift.refresh_subject()

  @doc "Whether `repo` has a (valid) `visual_baselines` block: the cheap test the callers gate on."
  @spec configured?(term(), String.t() | nil) :: boolean()
  def configured?(workspace, repo), do: match?({:ok, _}, Config.resolve(workspace, repo))

  @tried_cap 10

  @doc """
  Whether a refresh was already tried for `head` of task `task_id`, from either
  call site (the Watchdog's `:ci_failed` path and the ReviewGate's pre-review CI
  wait). The record lives on the ticket's `review_gate_state`, so the two
  processes share it and it survives a restart. Unreadable reads as "not tried".
  """
  @spec tried?(String.t() | nil, String.t() | nil) :: boolean()
  def tried?(task_id, head) when is_binary(task_id) and is_binary(head) do
    case Ash.get(Wardmast.Tasks.Issue, task_id) do
      {:ok, %{review_gate_state: %{"visual_tried_heads" => heads}}} when is_list(heads) ->
        head in heads

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def tried?(_task_id, _head), do: false

  @doc "Record that a refresh was tried for `head`: one go per head, whatever the outcome."
  @spec mark_tried(String.t() | nil, String.t() | nil) :: :ok
  def mark_tried(task_id, head) when is_binary(task_id) and is_binary(head) do
    with {:ok, %{review_gate_state: state}} <- Ash.get(Wardmast.Tasks.Issue, task_id) do
      heads = List.wrap((state || %{})["visual_tried_heads"])
      heads = Enum.take([head | Enum.reject(heads, &(&1 == head))], @tried_cap)
      Wardmast.Tasks.PullRequest.record_review_gate(task_id, %{visual_tried_heads: heads})
    end

    :ok
  rescue
    _ -> :ok
  end

  def mark_tried(_task_id, _head), do: :ok

  @hand_off_dir ".arbiter/visual-actual"

  @doc "The checkout-relative directory `hand_off/2` fills (git-ignored, never committed)."
  @spec hand_off_dir() :: String.t()
  def hand_off_dir, do: @hand_off_dir

  @type hand_off_entry :: %{
          baseline: String.t(),
          actual: String.t(),
          diff: String.t() | nil
        }

  @doc """
  Hands the head's own rendered images to a fix-pass worker that cannot fetch CI
  artifacts (GitHub #1593). The refresh (`refresh/1`) only takes main's drift; when
  the visual job fails on the branch's own intended UI change the agent has to
  judge the images, so they are staged, never applied.

  Downloads the head's visual job artifacts (`ci_job_artifacts/3`), maps each
  changed `*-actual.png` (and `*-diff.png`) to its baseline file (`Archive.plan/3`
  against `checkout`) and writes them under `.arbiter/visual-actual/` in
  `checkout`, named after the baseline file (relative to `baseline_dir`; the diff
  as `<name>-diff.png`). The directory is emptied first, so images of an earlier
  head never survive. Only artifacts of exactly `ctx.result.head_sha` are used,
  and the visual job must have failed (other failed jobs do not matter here).
  Nothing is committed and no baseline is touched.
  """
  @spec hand_off(ctx(), String.t()) :: {:ok, [hand_off_entry()]} | {:skip, term()}
  def hand_off(%{workspace: workspace, repo: repo} = ctx, checkout) when is_binary(checkout) do
    _ = File.rm_rf(Path.join(checkout, @hand_off_dir))

    case Config.resolve(workspace, repo) do
      {:ok, config} ->
        Wardmast.Mergers.prepare_with_repo(workspace, repo)
        stage_hand_off(ctx, config, checkout)

      :none ->
        {:skip, :not_configured}

      {:error, message} ->
        {:skip, {:invalid_config, message}}
    end
  rescue
    e ->
      Logger.warning("VisualBaselines: hand-off raised #{Exception.message(e)}")
      _ = File.rm_rf(Path.join(checkout, @hand_off_dir))
      {:skip, {:exception, Exception.message(e)}}
  end

  defp stage_hand_off(ctx, config, checkout) do
    %{adapter: adapter, mr_ref: mr_ref, result: result} = ctx
    head = Map.get(result, :head_sha)

    with :ok <- hand_off_supported(adapter),
         :ok <- present([head]),
         {:ok, archive} <- hand_off_artifacts(adapter, mr_ref, config, head),
         {:ok, plan} <- plan(archive, config, checkout) do
      write_hand_off(plan, config, checkout)
    end
  end

  defp hand_off_supported(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :ci_job_artifacts, 3),
      do: :ok,
      else: {:skip, :adapter_unsupported}
  end

  defp hand_off_artifacts(adapter, mr_ref, config, head) do
    case adapter.ci_job_artifacts(mr_ref, config.job, %{artifact: config.artifact}) do
      {:ok, %{sha: sha, failed_jobs: failed, archive: archive}} when is_binary(archive) ->
        cond do
          sha != head -> {:skip, :artifacts_for_another_head}
          config.job not in failed -> {:skip, :visual_job_not_failed}
          true -> {:ok, archive}
        end

      {:ok, _} ->
        {:skip, :no_artifacts}

      {:error, :job_not_failed} ->
        {:skip, :visual_job_not_failed}

      {:error, reason} ->
        {:skip, {:artifacts_unreadable, reason}}
    end
  end

  defp write_hand_off(plan, config, checkout) do
    root = Path.join(checkout, @hand_off_dir)

    entries =
      Enum.map(plan, fn entry ->
        rel = Path.relative_to(entry.baseline, config.baseline_dir)
        diff = if entry.diff, do: Path.rootname(rel) <> "-diff.png"
        {entry, rel, diff}
      end)

    result =
      Enum.reduce_while(entries, :ok, fn {entry, rel, diff}, :ok ->
        with :ok <- write_staged(root, rel, entry.bytes),
             :ok <- if(diff, do: write_staged(root, diff, entry.diff), else: :ok) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        {:ok,
         Enum.map(entries, fn {e, rel, diff} ->
           %{baseline: e.baseline, actual: rel, diff: diff}
         end)}

      {:error, reason} ->
        _ = File.rm_rf(root)
        {:skip, {:write_failed, reason}}
    end
  end

  defp write_staged(root, rel, bytes) do
    path = Path.join(root, rel)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, bytes)
    end
  end

  @doc """
  The fix-pass brief section for a `hand_off/2` outcome. The agent (and then the
  reviewer) judges the images: Wardmast never copies them over a baseline.
  """
  @spec hand_off_brief({:ok, [hand_off_entry()]} | {:skip, term()} | nil) :: String.t()
  def hand_off_brief(nil), do: ""
  # Not a visual failure (or nothing to hand over): the brief says nothing about images.
  def hand_off_brief({:skip, reason})
      when reason in [
             :not_configured,
             :visual_job_not_failed,
             :adapter_unsupported,
             :head_unknown
           ],
      do: ""

  def hand_off_brief({:ok, entries}) when is_list(entries) and entries != [] do
    list =
      Enum.map_join(entries, "\n", fn e ->
        diff = if e.diff, do: " (diff: #{@hand_off_dir}/#{e.diff})", else: ""
        "  * #{@hand_off_dir}/#{e.actual}  ->  #{e.baseline}#{diff}"
      end)

    """
    The visual job failed on this head, and its rendered images for exactly this
    head are in `#{@hand_off_dir}/` (git-ignored; you cannot download CI artifacts).
    Each is named after the baseline it would replace:
    #{list}
    Look at them. If they show the change this ticket intends, copy them over the
    listed baselines and commit them. If they show a regression, fix the code
    instead and do NOT copy them. Wardmast has not copied anything for you.
    """
  end

  def hand_off_brief(_other) do
    """
    The visual job's rendered images for this head could not be delivered to your
    checkout (`#{@hand_off_dir}/` is absent or empty), and you cannot download CI
    artifacts. Work from the failing-check output above; if the baselines must be
    regenerated and you cannot do it locally, say so in an `arb message coordinator`.
    """
  end

  @spec refresh(ctx()) :: outcome()
  def refresh(%{workspace: workspace, repo: repo} = ctx) do
    case Config.resolve(workspace, repo) do
      {:ok, config} ->
        # The forge adapter reads its config from the process dict; seed it from the
        # workspace's merge block (per-repo overrides, credentials_ref) like the merger.
        Wardmast.Mergers.prepare_with_repo(workspace, repo)
        run(ctx, config)

      :none ->
        {:skip, :not_configured}

      {:error, message} ->
        Logger.warning("VisualBaselines: #{repo}: #{message}; not refreshing")
        {:skip, {:invalid_config, message}}
    end
  rescue
    e ->
      Logger.warning("VisualBaselines: refresh raised #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp run(ctx, config) do
    %{adapter: adapter, mr_ref: mr_ref, result: result} = ctx
    head = Map.get(result, :head_sha)
    branch = Map.get(result, :head_ref)
    target = Map.get(result, :base_ref)

    with :ok <- supported(adapter),
         :ok <- present([head, branch, target]),
         {:ok, artifacts} <- artifacts(adapter, mr_ref, config, head),
         {:ok, green} <- green_run(adapter, mr_ref, config),
         {:ok, repo_path} <- repo_path(ctx) do
      in_checkout(repo_path, branch, head, fn path ->
        with {:ok, target_sha} <- fetch_target(path, target),
             :ok <- verdict(Drift.decide(path, target_sha, head, green, config)),
             {:ok, plan} <- plan(artifacts.archive, config, path) do
          apply_and_push(ctx, path, branch, plan)
        end
      end)
    end
  end

  defp supported(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :ci_job_artifacts, 3) and
         function_exported?(adapter, :last_green_job_sha, 3),
       do: :ok,
       else: {:skip, :adapter_unsupported}
  end

  defp present(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:skip, :head_unknown}
  end

  defp artifacts(adapter, mr_ref, config, head) do
    case adapter.ci_job_artifacts(mr_ref, config.job, %{artifact: config.artifact}) do
      {:ok, %{sha: sha, failed_jobs: failed, archive: archive}} when is_binary(archive) ->
        cond do
          sha != head -> {:skip, :artifacts_for_another_head}
          failed -- [config.job] != [] -> {:skip, {:other_jobs_failed, failed -- [config.job]}}
          config.job not in failed -> {:skip, :visual_job_not_failed}
          true -> {:ok, %{archive: archive}}
        end

      {:ok, _} ->
        {:skip, :no_artifacts}

      {:error, :job_not_failed} ->
        {:skip, :visual_job_not_failed}

      {:error, reason} ->
        {:skip, {:artifacts_unreadable, reason}}
    end
  end

  defp green_run(adapter, mr_ref, config) do
    case adapter.last_green_job_sha(mr_ref, config.job, %{}) do
      {:ok, sha} when is_binary(sha) or is_nil(sha) -> {:ok, sha}
      {:error, reason} -> {:skip, {:green_run_unreadable, reason}}
      _ -> {:skip, {:green_run_unreadable, :bad_reply}}
    end
  end

  defp repo_path(%{workspace: workspace, repo: repo}) do
    case LocalCompare.repo_path(workspace, repo) do
      path when is_binary(path) -> {:ok, path}
      _ -> {:skip, :no_local_repo}
    end
  end

  # A throwaway detached checkout at the branch's origin tip. If origin has moved
  # past the head the pipeline ran on, the artifacts describe a commit that is no
  # longer the branch: refuse.
  defp in_checkout(repo_path, branch, head, fun) do
    case Checkout.provision_branch(repo_path, branch, prefix: "visual-baselines") do
      {:ok, %{path: path, head_sha: tip}} ->
        try do
          if tip == head, do: fun.(path), else: {:skip, :branch_moved}
        after
          Checkout.teardown(path)
        end

      {:error, reason} ->
        {:skip, {:no_checkout, reason}}
    end
  end

  defp fetch_target(path, target) do
    ref = "refs/arbiter/visual/target-#{System.unique_integer([:positive])}"

    with {:ok, _} <- Drift.git(path, ["fetch", "--no-tags", "origin", "+#{target}:#{ref}"]),
         {:ok, sha} <- Drift.git(path, ["rev-parse", ref <> "^{commit}"]) do
      _ = Drift.git(path, ["update-ref", "-d", ref])
      {:ok, sha}
    else
      _ -> {:skip, :target_unavailable}
    end
  end

  defp verdict(:ok), do: :ok
  defp verdict({:skip, reason}), do: {:skip, reason}

  defp plan(archive, config, path) do
    case Archive.plan(archive, config, path) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp apply_and_push(ctx, path, branch, plan) do
    files = plan |> Enum.map(& &1.baseline) |> Enum.sort()

    with :ok <- write_files(path, plan),
         {:ok, _} <- Drift.git(path, ["add", "--" | files]),
         :ok <- only_staged(path, files),
         {:ok, sha} <- commit(path, plan),
         {:ok, credential} <- credential(ctx, path),
         :ok <- push(path, branch, credential) do
      Logger.info(
        "VisualBaselines: refreshed #{length(files)} baseline(s) on #{branch} for " <>
          "#{ctx.mr_ref} (#{sha})"
      )

      {:refreshed, %{sha: sha, files: files}}
    else
      {:error, _} = error -> error
    end
  end

  defp write_files(path, plan) do
    Enum.reduce_while(plan, :ok, fn %{baseline: rel, bytes: bytes}, :ok ->
      case File.write(Path.join(path, rel), bytes) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, rel, reason}}}
      end
    end)
  end

  # The plan is the whole change: if git stages anything else, stop.
  defp only_staged(path, files) do
    case Drift.git(path, ["diff", "--cached", "--name-only", "-z"]) do
      {:ok, out} ->
        staged = out |> String.split(<<0>>, trim: true) |> Enum.sort()
        if staged == files, do: :ok, else: {:error, {:unexpected_staged, staged}}

      {:error, reason} ->
        {:error, {:git, reason}}
    end
  end

  defp commit(path, plan) do
    body =
      "Replaced from the visual job's actual images:\n" <>
        Enum.map_join(plan, "\n", &"- #{&1.baseline}")

    args = [
      "-c",
      "user.name=Wardmast",
      "-c",
      "user.email=arbiter@localhost",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "--no-verify",
      "-m",
      commit_subject(),
      "-m",
      body
    ]

    with {:ok, _} <- Drift.git(path, args),
         {:ok, sha} <- Drift.git(path, ["rev-parse", "HEAD"]) do
      {:ok, sha}
    else
      {:error, reason} -> {:error, {:commit_failed, reason}}
    end
  end

  defp credential(%{workspace: workspace, repo: repo}, path) do
    case HostCredential.for_repo(workspace, repo, worktree_path: path) do
      {:ok, credential} -> {:ok, credential}
      {:error, reason} -> {:error, {:credential, HostCredential.format_error(reason)}}
    end
  end

  # Plain push, never forced: a branch that moved since the checkout was cut
  # rejects it and nothing is overwritten.
  defp push(path, branch, credential) do
    env = HostCredential.push_env(credential)

    case System.cmd("git", ["-C", path, "push", "origin", "HEAD:refs/heads/" <> branch],
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:push_failed, String.trim(out)}}
    end
  end
end
