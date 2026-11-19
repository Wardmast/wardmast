defmodule Wardmast.Worker.ResumeSlot do
  @moduledoc """
  Whether a resume may re-enter a task right now, given the dispatch cap
  (bd-92mx1m).

  ## The incident

  On 2026-09-23, with the install-wide cap at 1 (then `conductor_system_max_concurrent`,
  since removed by DC1), bd-3usjdj ran out
  of ReviewGate fix rounds and parked at `:waiting_on_you`, which releases its
  slot (bd-45pwo1). Autopilot correctly admitted bd-d7mfdq into the freed slot.
  Four seconds later the coordinator ran `arb worker resume bd-3usjdj`, and
  `Wardmast.Worker.Dispatch.resume/2` re-entered it without asking anyone about
  the cap: two tasks in flight under a cap of 1, and the scheduler could admit
  nothing until both merged.

  ## The rule: the pin pool's seat (DC8, the only rule since DC12)

  For a ticket whose pin account (`implementer_account_id`, else the account
  its workspace meters its last authoring provider under), the question is the
  pin pool's **seat** (`docs/design/provider-dynamic-concurrency.md` §3.2, §7):

    * **In progress** — the ticket holds its pin seat in every phase, held for
      quota and idle included, so a resume needs nothing new: `{:ok, :held}`.
      This is the #1969/#1995 no-deadlock guarantee: a round for a ticket
      already In progress is never a new admission.
    * **Not In progress** — the resume takes the ticket back into In progress:
      it needs a free seat on its pin pool (`Wardmast.Accounts.SeatCheck`).
    * **`follow_up: true`** — a CI fix or conflict pass
      (`Wardmast.Workflows.MergeQueue.PassAdmission`) is a follow-up of in-flight
      work and is never held for a full pool (I9): `{:ok, :follow_up}`.

  No worker rows are read; the stored state decides In progress (bd-asxw4e).

  ## When no seat is free

  Which of the two happens is the only thing the caller's origin decides:

    * `origin: :human` (the default — refusing is the one answer that neither
      fails silently nor bypasses) → `{:error, {:slot_cap_full, info}}`, which
      every human surface renders with `refusal_message/1`. `force: true`
      overrides, and the override is written to the audit log as a
      `slot_cap_override` event (`Wardmast.Events`) naming the actor, the cap
      and the holders.
    * `origin: :automatic` → `{:defer, info}`. `Dispatch` hands the resume to
      `Wardmast.Board.Autopilot.defer_resume/4`, which starts it as soon as a
      seat frees, ahead of any new Ready dispatch.

  `slot_admitted: true` marks a resume the scheduler has already admitted
  (the Autopilot draining a deferred resume); it is not re-checked. `:account`
  and `:seat_opts` are seams.
  """

  alias Wardmast.Accounts.Resolver
  alias Wardmast.Accounts.SeatCheck
  alias Wardmast.Agents.ModelFamily
  alias Wardmast.Tasks.Issue
  alias Wardmast.Workers.Run

  require Ash.Query
  require Logger

  @typedoc "What a refusal / deferral / override knows about the cap."
  @type info :: %{
          required(:task_id) => String.t(),
          required(:cap) => non_neg_integer(),
          required(:holders) => [String.t()],
          optional(:seat) => SeatCheck.info()
        }

  @type result ::
          {:ok, :held | :acquired | :forced | :admitted | :follow_up}
          | {:defer, info()}
          | {:error, {:slot_cap_full, info()}}

  # Latest-run shapes that mean "cut off by a restart, not ended on its own
  # terms" — the orphan sweep's reason, the graceful-shutdown outcome, and a
  # row the sweep has not reached yet.
  @restart_failure_reasons ["server restarted", "server shutdown"]

  @doc """
  Decide whether a resume of `task` may start now. See the moduledoc.

  Options:

    * `:origin` — `:human` (default) or `:automatic`.
    * `:force` — override a full cap (human surfaces only); recorded.
    * `:actor` — who forced it, for the audit record.
    * `:slot_admitted` — the scheduler already admitted this resume.
    * `:provider` / `:model` — the provider and model the resume will run on
      (the caller's, a `provider_constraint`'s, routing's), under `enforce`: the seat
      is checked on that provider's account and the model's pool instead of the
      original run's pin (bd-dhrb7j).
    * `:follow_up` — a CI fix or conflict pass (DC8): under `enforce` never
      held for a full pool; ignored otherwise.
  """
  @spec admit(Issue.t(), keyword()) :: result()
  def admit(%Issue{} = task, opts \\ []) do
    if Keyword.get(opts, :slot_admitted) == true do
      {:ok, :admitted}
    else
      admit_seat(task, pin_account!(task, opts), opts)
    end
  end

  # ---- enforce (DC8) -----------------------------------------------------------

  # The pin account. Unreadable reads as no account, which fails open like every
  # other read of the ceiling (a bug here must not stop the fleet).
  defp pin_account!(%Issue{} = task, opts) do
    Keyword.get_lazy(opts, :account, fn -> pin_account(task, opts) end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # bd-dhrb7j: the seat a resume takes is on the pool it will RUN on. The pin
  # (`implementer_account_id`, else the last authoring provider's account) is
  # where the run started; a resume that moves to another provider — the
  # caller's, a `provider_constraint`'s, routing's — is admitted on that
  # provider's account, or a ticket whose original provider is stopped could
  # never be resumed elsewhere. `:provider` is that prediction, nil when the
  # resume stays where it was.
  defp pin_account(%Issue{} = task, opts) do
    provider = Keyword.get(opts, :provider)
    pinned = original_account(task)

    cond do
      is_nil(provider) -> pinned
      pinned && same_provider?(pinned.provider, provider) -> pinned
      true -> Resolver.account(task.workspace_id, provider) || pinned
    end
  end

  defp original_account(%Issue{implementer_account_id: id}) when is_binary(id),
    do: Resolver.get(id)

  defp original_account(%Issue{id: id, workspace_id: ws_id}) do
    provider = Run.latest_authoring_provider(id) || Wardmast.Quota.default_provider(ws_id)
    Resolver.account(ws_id, provider)
  end

  defp same_provider?(a, b), do: Resolver.provider_atom(a) == Resolver.provider_atom(b)

  defp admit_seat(%Issue{} = task, account, opts) do
    cond do
      Keyword.get(opts, :follow_up) == true -> {:ok, :follow_up}
      task.state == :active -> {:ok, :held}
      is_nil(account) -> {:ok, :acquired}
      true -> acquire_seat(task, account, opts)
    end
  end

  # With no `:model` the pin pool is the account's lowest budget (§3.1); a
  # model (`--model`, routing's pick) names its own pool and weighs its seat.
  defp acquire_seat(%Issue{} = task, account, opts) do
    model = presence(Keyword.get(opts, :model))

    seat_opts =
      Keyword.merge(
        [
          workspace_id: task.workspace_id,
          pool: model && ModelFamily.classify(account.provider, model).pool,
          model: model,
          priority: task.priority,
          exclude_task: task.id
        ],
        Keyword.get(opts, :seat_opts, [])
      )

    case SeatCheck.check(account, seat_opts) do
      {:ok, _seat} ->
        {:ok, :acquired}

      {:full, seat} ->
        over_cap(
          task,
          %{task_id: task.id, cap: seat.limit, holders: seat.holders, seat: seat},
          opts
        )
    end
  end

  @doc """
  The operator-facing refusal for `{:error, {:slot_cap_full, info}}`. One
  source of truth for MCP, the REST API (and so the CLI), and the dashboard.
  """
  @spec refusal_message(info()) :: String.t()
  def refusal_message(%{task_id: task_id, seat: %{}} = info) do
    "no free seat to resume #{task_id}: #{limit_phrase(info)}. #{task_id} is not In progress, " <>
      "so it holds no seat on its pool and resuming it is a new admission. Wait for a seat " <>
      "to free, or resume with force (MCP `force: true`, `arb worker resume --force`) to go " <>
      "over — the override is recorded."
  end

  @doc """
  Names the binding limit — the account ceiling, the workspace share or the
  install cap — and who is counted against it (bd-48prlb). Falls back to the
  workspace-framed number when the binding limit is unknown. Shared by the
  refusal and the deferred-resume log line.
  """
  @spec limit_phrase(info()) :: String.t()
  def limit_phrase(%{seat: %{} = seat, holders: [_ | _] = holders}),
    do: "#{SeatCheck.describe(seat)}, held by #{Enum.join(holders, ", ")}"

  def limit_phrase(%{seat: %{} = seat}), do: SeatCheck.describe(seat)

  # ---- internals -----------------------------------------------------------

  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil

  @doc """
  Was `task_id`'s latest main run cut off by a restart rather than ended on its
  own terms? What a task with no registered worker is judged by: such a task
  was in flight, and still holds its slot.
  """
  @spec cut_off_by_restart?(String.t()) :: boolean()
  def cut_off_by_restart?(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and kind == :implement)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{state: state}] when state != :finished -> true
      [%Run{outcome: :interrupted}] -> true
      [%Run{failure_reason: reason}] when reason in @restart_failure_reasons -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp over_cap(task, info, opts) do
    cond do
      Keyword.get(opts, :force) == true ->
        record_override(task, info, opts)
        {:ok, :forced}

      Keyword.get(opts, :origin, :human) == :automatic ->
        {:defer, info}

      true ->
        {:error, {:slot_cap_full, info}}
    end
  end

  defp record_override(%Issue{workspace_id: ws_id}, info, opts) do
    Logger.warning(
      "ResumeSlot: #{info.task_id} resumed over the concurrency limit (#{limit_phrase(info)}) by force from #{inspect(Keyword.get(opts, :actor))}"
    )

    Wardmast.Events.broadcast(ws_id, "slot_cap_override", %{
      "task_id" => info.task_id,
      "cap" => info.cap,
      "holders" => info.holders,
      "actor" => Keyword.get(opts, :actor),
      "origin" => opts |> Keyword.get(:origin, :human) |> to_string()
    })
  end
end
