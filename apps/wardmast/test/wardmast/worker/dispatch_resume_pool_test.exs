defmodule Wardmast.Worker.DispatchResumePoolTest do
  @moduledoc """
  bd-dhrb7j (#1435): `Dispatch.resume/2` admits the ticket on the pool it will
  RUN on, not the pool of the run's original provider.

  Incident (bd-a933es): the ticket was pinned to `antigravity:default` (gemini),
  whose pool was in a quota-stop hold. `worker resume --require-provider claude`
  (and `--model sonnet`) was refused "no free seat on antigravity:default gemini"
  because admission read the original run's pin, never the provider constraint
  or the model the resume asked for.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Wardmast.Quota.Budget
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Worker.Dispatch

  setup do
    ResumeSlotFixture.setup_repo!(stub: "exec sleep 30\n")
    # The fixture pins the primary's cap to 1; the resume under test must not be
    # held by it, only by the account seat check.
    ResumeSlotFixture.put_local_cap(10)

    on_exit(fn -> Wardmast.Settings.set_scheduler_admission(nil) end)

    ws =
      Ash.create!(Workspace, %{
        name: "rp-#{System.unique_integer([:positive])}",
        prefix: "rp#{System.unique_integer([:positive])}"
      })

    claude = account!(:claude)
    agy = account!(:antigravity)
    link!(ws, claude)
    link!(ws, agy)

    # Ran on Claude and parked, PR open (Merging: holds no slot, no seat).
    task = Ash.create!(Issue, %{title: "stranded", workspace_id: ws.id})
    ResumeSlotFixture.park!(task)

    # ... but pinned to the agy account, whose Gemini pool is stopped.
    task =
      task.id
      |> then(&Ash.get!(Issue, &1))
      |> Ash.Changeset.for_update(:pin_implementer, %{
        implementer_account_id: agy.id,
        implementer_family: "google"
      })
      |> Ash.update!()

    {:ok, "enforce"} = Wardmast.Settings.set_scheduler_admission("enforce")

    %{ws: ws, claude: claude, agy: agy, task: task}
  end

  defp account!(provider) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{provider}-#{System.unique_integer([:positive])}",
      max_concurrent: 3
    })
  end

  defp link!(ws, account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id
    })
  end

  defp budgets(ctx, claude_budget) do
    [
      %Budget{
        account: ctx.agy.id,
        pool: "antigravity:gemini_models",
        budget: 0,
        binding: {:window, "5h"},
        reason: "quota-stop hold"
      },
      %Budget{
        account: ctx.claude.id,
        pool: "claude",
        budget: claude_budget,
        binding: {:window, "5h"},
        reason: "5h ahead of its line"
      }
    ]
  end

  defp resume(task, ctx, opts) do
    {claude_budget, opts} = Keyword.pop(opts, :claude_budget, 2)

    Dispatch.resume(
      task.id,
      [start_driver: false, seat_opts: [budgets: budgets(ctx, claude_budget)]] ++ opts
    )
  end

  test "a plain resume is admitted on the pool it runs on, not the stopped pin's", ctx do
    # It resumes on Claude (the last authoring run); Claude has room.
    assert {:ok, %{worker_pid: pid}} = resume(ctx.task, ctx, [])
    assert is_pid(pid)
  end

  test "and is refused there when that pool is the one that is full", ctx do
    assert {:error, {:slot_cap_full, %{seat: %{account_id: account_id, pool: "claude"}}}} =
             resume(ctx.task, ctx, claude_budget: 0)

    assert account_id == ctx.claude.id
  end

  test "a caller-named provider is admitted on that provider's account", ctx do
    assert {:ok, %{worker_pid: pid}} = resume(ctx.task, ctx, agent_type: :claude)
    assert is_pid(pid)
  end

  test "a provider_constraint steers admission to an allowed provider's account", ctx do
    task = Ash.update!(ctx.task, %{provider_constraint: %{"require" => ["claude"]}})

    assert {:ok, %{worker_pid: pid}} = resume(task, ctx, [])
    assert is_pid(pid)
  end
end
