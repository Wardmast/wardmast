defmodule Wardmast.Sessions.Pair do
  @moduledoc """
  The **pair** session kind (bd-7p6a9o): a hands-on agent session bound to one
  ticket, worked together with the operator.

  The coordinator stays a pure router; hands-on work happens here instead. A
  pair session is a `Wardmast.Sessions.Session` row of kind `:pair` carrying
  the ticket's id in `issue_id` — the same binding column a refine session
  uses, so the partial unique index `sessions_live_issue_binding_index` holds
  "at most one live session per ticket" across both kinds.

  ## What opening one does

  `open/2` is the one door (the ticket page's **Pair** button, `ward pair
  <ticket>`, the `pair_open` MCP tool and `POST /api/issues/:id/pair` all go
  through it):

    * **The ticket's worktree, on the ticket's branch** — provisioned or reused
      by `Wardmast.Worker.Dispatch.provision_worktree/2`, which is the very
      code a dispatch provisions with. A worker that later picks the ticket up
      lands in the same checkout on the same branch.
    * **A ticket-scoped token** — `Wardmast.Sessions.Provisioning.mint_token/2`
      gives a `:pair` row the ticket's worker-tier token, carrying the session
      id so it dies with the session (`Wardmast.MCP.Scope.mint_pair/4`).
    * **The pair doctrine** — `Wardmast.Sessions.Instructions`' pair variant,
      rendered into the session's `CLAUDE_CONFIG_DIR`, never into the
      worktree (whose own `CLAUDE.md` belongs to the repo).

  ## The claim

  The live row **is** the claim. While it exists, `Wardmast.Worker.Dispatch`
  refuses to start a worker on the ticket — manual, forced or resumed — and the
  scheduler holds the card (`{:pair_session, session_id}` in
  `Wardmast.Tasks.Lifecycle.Dispatchable`). There is nothing to release by
  hand: every way a session ends — Done, `close/2`, the dock's Kill, the idle
  reaper, the adoption sweep finding the scope gone — runs through
  `Wardmast.Sessions.mark_ended/2`, and an ended row claims nothing.

  Opening refuses a ticket a worker is already driving (`:worker_active`): two
  agents in one worktree interleave commits. The worker check runs both before
  and after the row is written, so a dispatch racing the open is caught on one
  side or the other.

  ## Ending without Done

  `close/2` ends the session and touches nothing else: the worktree, its
  commits and whatever was pushed stay exactly where they are, for a later
  pair session or a worker to continue from.
  """

  require Ash.Query
  require Logger

  alias Wardmast.Sessions
  alias Wardmast.Sessions.Refine
  alias Wardmast.Sessions.Session
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Worker.PrepushCheck
  alias Wardmast.Worker.Worktree
  alias Wardmast.Workers.Run

  @pairable_states [:backlog, :queued, :active]

  # The `role` a pair session's run carries — distinct from a worker's "base",
  # so the estimator never counts it as a second dispatch of the ticket.
  @run_role "pair"

  # How long a caller waits on Done (the pre-push recipe's own budget is
  # about three minutes), and how long a session ending itself waits for its
  # answer to reach it.
  @finish_timeout_ms :timer.minutes(10)
  @self_end_delay_ms 2_000

  @typedoc "What `open/2` hands back: the session, and whether it already existed."
  @type opened :: %{session: Session.t(), reopened?: boolean()}

  @doc """
  Whether `issue` can be paired on — the predicate the ticket page's button
  renders from, so "where the button appears" and "what `open/2` accepts"
  have one definition.

  Backlog, Ready and In progress. A Merging ticket's work is in review, and a
  verifying or closed one is past the point where more hands-on work belongs
  on this ticket.
  """
  @spec eligible?(Issue.t() | nil) :: boolean()
  def eligible?(%Issue{state: state}), do: state in @pairable_states
  def eligible?(_issue), do: false

  @doc """
  The live pair session bound to `issue_id`, if there is one. "Live" is any
  status but `:ended`, like `Wardmast.Sessions.Refine.live_session/1`.
  """
  @spec live_session(String.t() | nil) :: {:ok, Session.t()} | :none
  def live_session(issue_id) when is_binary(issue_id) and issue_id != "" do
    Session
    |> Ash.Query.filter(issue_id == ^issue_id and kind == :pair and status != :ended)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [session] -> {:ok, session}
      [] -> :none
    end
  end

  def live_session(_issue_id), do: :none

  @doc """
  Every live claim, as `%{ticket_id => session_id}` — what the scheduler holds
  cards on (`Wardmast.Board.Snapshot`). One indexed read for the whole board.
  """
  @spec claims() :: %{optional(String.t()) => String.t()}
  def claims do
    Session
    |> Ash.Query.filter(kind == :pair and status != :ended and not is_nil(issue_id))
    |> Ash.Query.select([:id, :issue_id])
    |> Ash.read!()
    |> Map.new(&{&1.issue_id, &1.id})
  end

  @doc """
  The live pair session's id claiming `issue_id`, or `nil`. The check every
  worker start makes (`Wardmast.Worker.Dispatch`, `Wardmast.Worker.start/1`).
  """
  @spec claimed_by(String.t() | nil) :: String.t() | nil
  def claimed_by(issue_id) do
    case live_session(issue_id) do
      {:ok, %Session{id: id}} -> id
      :none -> nil
    end
  end

  @doc """
  Open the pair session for `issue`: reopen the live one if there is one,
  otherwise provision the ticket's worktree and launch it.

  Returns `{:ok, %{session: session, reopened?: boolean}}`, or
  `{:error, reason}`: `:issue_not_found`, `:not_pairable` (see `eligible?/1`),
  `:no_workspace`, `:no_repo`, `:worker_active` (a worker is driving the
  ticket), `:refine_session_live` (the ticket's refine session holds its one
  live-session slot), or whatever provisioning the worktree or launching the
  session returned.

  Options are passed through to `Wardmast.Sessions.launch/1` (`:runner` for
  tests), except the ones this function owns: `:name`, `:kind`, `:issue_id`,
  `:workspace_id`, `:cwd`, `:can_dispatch`, `:provider`, `:pair`, `:refine`,
  `:model`, `:thinking` and `:thinking_argv`. A pair session runs Claude Code:
  its instructions live in a Claude config dir, never in the worktree.
  """
  @spec open(Issue.t() | String.t(), keyword()) :: {:ok, opened()} | {:error, term()}
  def open(issue, opts \\ [])

  def open(issue_id, opts) when is_binary(issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, issue} -> open(issue, opts)
      {:error, _} -> {:error, :issue_not_found}
    end
  end

  def open(%Issue{} = issue, opts) do
    cond do
      not eligible?(issue) -> {:error, :not_pairable}
      blank?(issue.workspace_id) -> {:error, :no_workspace}
      true -> open_eligible(issue, opts)
    end
  end

  @doc """
  End the ticket's pair session **without** Done.

  Only the session ends — its token is revoked and the claim released. The
  worktree, the branch and anything pushed are left exactly as they are, so a
  later pair session or a worker continues from them. `{:error,
  :no_pair_session}` when there is none.
  """
  @spec close(Issue.t() | String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def close(issue_or_id, opts \\ []) do
    with {:ok, session} <- live_session_for(issue_or_id) do
      Sessions.kill(
        session.id,
        Keyword.merge([reason: "pair session closed without done"], Keyword.take(opts, [:runner]))
      )
    end
  end

  @doc """
  **Done**: finish the ticket's pair session through the completion path a
  worker's `arb done` takes.

    1. **The commit gate**, in the session's worktree: on the ticket's branch,
       nothing uncommitted, at least one commit ahead of the base, no injected
       agent config committed (`{:error, {:commit_gate, reason}}`); then the
       repo's pre-push recipe (`worker.repos.<repo>.pre_push_checks`), whose
       red step comes back with its output (`{:error, {:prepush_failed,
       %{status:, output:}}}`). A refused Done changes nothing: the session,
       its claim and the ticket stay exactly as they were, so the pair fixes
       it and runs Done again.
    2. **The hand-off**: the ticket goes In progress, a run is recorded
       against it (`kind: :implement`, `role: "pair"`), and
       `Wardmast.Worker.complete_without_author/2` routes the branch the way a
       worker's would be routed — the ReviewGate first when the workspace
       requires review, then the PR (labelled `pair-authored`), CI and the
       merge queue's Watchdog.
    3. **The end**: the session ends with reason `"done"`, which releases the
       claim. When the caller *is* the session (`:caller_session_id`, the
       agent calling `pair_done`), the end waits a moment so its answer can
       reach it first.

  Runs supervised and unlinked from the caller — a client that disconnects
  mid-way cannot interrupt a hand-off half done — and one at a time per
  ticket (`{:error, :finish_in_progress}`). The caller waits up to `:timeout`
  (default ten minutes); past it the answer is `{:ok, %{route: :running}}` and
  the work completes regardless.

  Returns `{:ok, %{route: :in_review | :pr_opened, ...}}`, `{:error,
  :no_pair_session}`, or one of the refusals above.

  ## Options

    * `:runner` — the session command runner, for tests.
    * `:caller_session_id` — the calling session's id, when Done comes from
      inside a session.
    * `:completion` — extra context for `Wardmast.Worker.complete_without_author/2`
      (the merge and review overrides tests pass).
    * `:timeout` — how long the caller waits, in milliseconds.
  """
  @spec finish(Issue.t() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(issue_or_id, opts \\ []) do
    with {:ok, session} <- live_session_for(issue_or_id) do
      task =
        Task.Supervisor.async_nolink(Wardmast.TaskSupervisor, fn ->
          locked_finish(session, opts)
        end)

      case Task.yield(task, Keyword.get(opts, :timeout, @finish_timeout_ms)) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, {:finish_crashed, reason}}

        nil ->
          _ = Task.ignore(task)
          {:ok, %{route: :running}}
      end
    end
  end

  @doc "The session's display name — `Pair <id>: <title>`."
  @spec display_name(Issue.t()) :: String.t()
  def display_name(%Issue{id: id, title: title}) do
    case title do
      t when is_binary(t) and t != "" -> "Pair #{id}: #{t}"
      _ -> "Pair #{id}"
    end
  end

  # ---- internals ----------------------------------------------------------

  defp open_eligible(%Issue{} = issue, opts) do
    case live_session(issue.id) do
      {:ok, session} -> {:ok, %{session: session, reopened?: true}}
      :none -> launch(issue, opts)
    end
  end

  defp launch(%Issue{} = issue, opts) do
    with :ok <- ensure_no_worker(issue.id),
         :ok <- ensure_no_refine_session(issue.id),
         {:ok, worktree} <- Dispatch.provision_worktree(issue, Keyword.take(opts, [:repo])) do
      workspace = workspace(issue.workspace_id)
      selection = Refine.agent_selection(workspace)

      launch_opts =
        opts
        |> Keyword.drop([
          :name,
          :kind,
          :issue_id,
          :workspace_id,
          :cwd,
          :can_dispatch,
          :provider,
          :pair,
          :refine,
          :repo,
          :model,
          :thinking,
          :thinking_argv
        ])
        |> Keyword.merge(
          name: display_name(issue),
          kind: :pair,
          issue_id: issue.id,
          workspace_id: issue.workspace_id,
          cwd: worktree.path,
          can_dispatch: false,
          pair: pair_context(issue, workspace, worktree),
          model: selection.model,
          thinking: Refine.thinking(),
          thinking_argv: selection.thinking_argv
        )

      launch_opts
      |> safe_launch()
      |> settle_launch(issue, opts)
    end
  end

  defp settle_launch({:ok, session}, %Issue{} = issue, opts) do
    # The second half of the worker check: a dispatch that passed its own
    # pair-session check a moment before this row existed would otherwise
    # leave a worker and a pair session in one worktree.
    case ensure_no_worker(issue.id) do
      :ok ->
        {:ok, %{session: session, reopened?: false}}

      {:error, :worker_active} = refused ->
        _ = Sessions.kill(session.id, reason: "a worker took the ticket", runner: opts[:runner])
        refused
    end
  end

  # A concurrent open that lost the race at `sessions_live_issue_binding_index`:
  # the winner's row is committed by the time ours was refused, so re-reading
  # is reading the answer that now exists.
  defp settle_launch({:error, reason}, %Issue{} = issue, _opts) do
    case live_session(issue.id) do
      {:ok, session} -> {:ok, %{session: session, reopened?: true}}
      :none -> {:error, reason}
    end
  end

  # An insert refused by a plain database index surfaces as a raise, not an
  # `{:error, _}` (see `Wardmast.Sessions.Refine`).
  defp safe_launch(launch_opts) do
    Sessions.launch(launch_opts)
  rescue
    error ->
      Logger.warning(
        "Sessions.Pair: launching the pair session for #{launch_opts[:issue_id]} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  end

  defp ensure_no_worker(issue_id) do
    case Worker.whereis(issue_id) do
      nil -> :ok
      pid -> if worker_finished?(pid), do: :ok, else: {:error, :worker_active}
    end
  end

  defp worker_finished?(pid) do
    Worker.finished?(Worker.state(pid))
  catch
    # Gone between the lookup and the call: nothing is driving the ticket.
    :exit, _ -> true
  end

  defp ensure_no_refine_session(issue_id) do
    case Refine.live_session(issue_id) do
      {:ok, _session} -> {:error, :refine_session_live}
      :none -> :ok
    end
  end

  # ---- Done ---------------------------------------------------------------

  # One Done per ticket at a time: a double click must not run two hand-offs.
  defp locked_finish(%Session{issue_id: issue_id} = session, opts) do
    lock = {{__MODULE__, :finish, issue_id}, self()}

    case :global.trans(lock, fn -> do_finish(session, opts) end, [node()], 0) do
      :aborted -> {:error, :finish_in_progress}
      result -> result
    end
  end

  defp do_finish(%Session{} = session, opts) do
    with {:ok, issue} <- fetch_issue(session.issue_id),
         :ok <- finishable(issue),
         {:ok, checkout} <- Dispatch.ticket_checkout(issue),
         :ok <- on_ticket_branch(session.cwd, checkout.branch),
         :ok <- commit_gate(session.cwd, checkout.target_branch),
         :ok <- prepush(issue, checkout, session.cwd),
         {:ok, issue} <- Issue.start_work(issue),
         {:ok, run} <- record_run(issue, session, checkout),
         {:ok, route} <- hand_off(issue, session, checkout, opts) do
      {:ok, %{route: route, run_id: run.id, session: end_session(session, opts)}}
    end
  end

  defp fetch_issue(issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, issue} -> {:ok, issue}
      {:error, _} -> {:error, :issue_not_found}
    end
  end

  defp finishable(%Issue{} = issue) do
    if eligible?(issue), do: :ok, else: {:error, {:not_finishable, issue.state}}
  end

  # The branch a worker would push for this ticket: Done hands *that* branch
  # on, so a worktree someone switched elsewhere is refused, not shipped.
  defp on_ticket_branch(worktree, branch) do
    case Worktree.current_branch(worktree) do
      {:ok, ^branch} -> :ok
      {:ok, other} -> {:error, {:commit_gate, {:wrong_branch, other, branch}}}
      {:error, reason} -> {:error, {:commit_gate, {:git_failed, reason}}}
    end
  end

  # The worker's commit gate (`Wardmast.Worker`'s `commit_gate/1`), except that
  # a git error refuses rather than failing open: an interactive Done can
  # simply be run again, where a headless run would be stranded.
  defp commit_gate(worktree, target) do
    case Worktree.completion_state(worktree, target) do
      {:ok, :ready} ->
        case Worktree.has_injected_config_in_commits?(worktree, target) do
          {:ok, true} -> {:error, {:commit_gate, :secret_in_commit}}
          _ -> :ok
        end

      {:ok, reason} ->
        {:error, {:commit_gate, reason}}

      {:error, reason} ->
        {:error, {:commit_gate, {:git_failed, reason}}}
    end
  end

  # The repo's pre-push recipe, run in the worktree on the host — the pair
  # session's own machine. A red step refuses Done with its output; a timeout
  # or a recipe that could not run fails open, as it does for a worker
  # (`Wardmast.Worker.PrepushCheck`'s outcomes), CI being the backstop.
  defp prepush(%Issue{} = issue, checkout, worktree) do
    case PrepushCheck.resolve(workspace(issue.workspace_id), checkout.repo) do
      nil ->
        :ok

      spec ->
        case PrepushCheck.run_steps(spec, worktree, target: checkout.target_branch) do
          %{result: :ok} ->
            :ok

          %{result: {:failed, status, output}} ->
            {:error, {:prepush_failed, %{status: status, output: PrepushCheck.tail(output)}}}

          %{result: other} ->
            Logger.warning(
              "Sessions.Pair: pre-push checks for #{issue.id} did not run to a verdict " <>
                "(#{inspect(other)}); failing open as the worker gate does"
            )

            :ok
        end
    end
  end

  # The pair session's run, against the ticket like a worker's: the ticket's
  # history shows who worked it, and the completion path writes its outcome.
  defp record_run(%Issue{} = issue, %Session{} = session, checkout) do
    Ash.create(Run, %{
      task_id: issue.id,
      base_task_id: issue.id,
      task_title: issue.title,
      repo: checkout.repo || issue.repo,
      workspace_id: issue.workspace_id,
      kind: :implement,
      role: @run_role,
      state: :working,
      provider: "claude",
      session_id: session.provider_session_id,
      started_at: session.started_at
    })
  end

  defp hand_off(%Issue{} = issue, %Session{} = session, checkout, opts) do
    ctx =
      Map.merge(
        %{
          branch: checkout.branch,
          worktree_path: session.cwd,
          target_branch: checkout.target_branch,
          repo: checkout.repo,
          repo_path: checkout.repo_path,
          pair_authored: true
        },
        Keyword.get(opts, :completion, %{})
      )

    case Worker.complete_without_author(issue.id, ctx) do
      {:ok, route} -> {:ok, route}
      {:error, reason} -> {:error, {:hand_off_failed, reason}}
    end
  end

  # Done releases the claim by ending the session. A session ending itself
  # (the agent called `pair_done`) is given a moment for the answer to reach
  # it before its pane goes.
  defp end_session(%Session{id: id} = session, opts) do
    if Keyword.get(opts, :caller_session_id) == id do
      delay = Keyword.get(opts, :self_end_delay_ms, @self_end_delay_ms)

      {:ok, _pid} =
        Task.Supervisor.start_child(Wardmast.TaskSupervisor, fn ->
          Process.sleep(delay)
          _ = Sessions.kill(id, reason: "done", runner: opts[:runner])
        end)

      :deferred
    else
      case Sessions.kill(id, reason: "done", runner: opts[:runner]) do
        {:ok, ended} ->
          ended

        {:error, reason} ->
          Logger.warning("Sessions.Pair: could not end #{session.id} after Done: #{inspect(reason)}")
          nil
      end
    end
  end

  defp live_session_for(%Issue{id: id}), do: live_session_for(id)

  defp live_session_for(issue_id) when is_binary(issue_id) do
    case live_session(issue_id) do
      {:ok, session} -> {:ok, session}
      :none -> {:error, :no_pair_session}
    end
  end

  # The `:pair` map `Wardmast.Sessions.Instructions.render/2` renders from, and
  # what `Wardmast.Sessions.Provisioning` reads the token's repo claim from.
  defp pair_context(%Issue{} = issue, workspace, worktree) do
    %{
      issue: issue,
      workspace: workspace,
      worktree: worktree.path,
      branch: worktree.branch,
      target_branch: worktree.target_branch,
      repo: worktree.repo,
      repo_path: worktree.repo_path
    }
  end

  defp workspace(nil), do: nil

  defp workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> workspace
      {:error, _} -> nil
    end
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
end
