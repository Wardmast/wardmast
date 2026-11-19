defmodule Wardmast.Board.AdmissionShadowE2ETest do
  @moduledoc """
  The admission walk end to end (DC6, DC8, DC12): the real Autopilot reads the
  real board (`Snapshot.load/1`, `Wardmast.Board.WalkInputs`, the walk) and
  hands its card to the real `Dispatch.dispatch/2`, which spawns a (stubbed)
  worker and writes its run row. The one seam is where the published budgets
  come from: the test env's `Budget.Server` computes nothing, so they are
  handed to `WalkInputs` and the seat check directly.

    * with room on the pool the walk's card goes, and its run carries the
      reverse shadow as `routing_decision.admission_shadow`;
    * with the pool at 0 seats nothing goes, and the hold change is an
      `admission_shadow_events` row.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Wardmast.Board.{AdmissionShadowEvent, Autopilot, Snapshot}
  alias Wardmast.Quota.Budget
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Test.ResumeSlotFixture
  alias Wardmast.Workers.Run

  require Ash.Query

  setup do
    ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(10)

    ws =
      Ash.create!(Workspace, %{
        name: "e2e-#{System.unique_integer([:positive])}",
        prefix: "e2e#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "e2e-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    ready = fn title, priority ->
      created =
        Ash.create!(Issue, %{
          title: title,
          workspace_id: ws.id,
          priority: priority,
          acceptance: "- e2e fixture"
        })

      Ash.update!(created, %{}, action: :promote_to_ready)
    end

    %{account: account, first: ready.("first", 1), second: ready.("second", 2)}
  end
  end

  defp run_of(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  # ---- enforce (DC8) -----------------------------------------------------------

  # The same budget reaches the walk (`walk_opts`) and the dispatch's seat check
  # (`seat_opts`): the test env's `Budget.Server` publishes nothing.
  defp enforcing_autopilot(account, budget, reason) do
    budget = %Budget{
      account: account.id,
      pool: "claude",
      budget: budget,
      binding: {:window, "5h"},
      reason: reason,
      ceiling: %{max_concurrent: 3, share: nil}
    }

    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        topics: [],
        follow_up: false,
        registry_settled?: fn -> true end,
        snapshot: fn opts ->
          Snapshot.load(Keyword.put(opts, :walk_opts, budgets: [budget]))
        end,
        dispatch: fn id, extra ->
          Wardmast.Worker.Dispatch.dispatch(
            id,
            Keyword.merge(
              [start_claude: true, dispatched_by: "autopilot", seat_opts: [budgets: [budget]]],
              extra
            )
          )
        end
      )

    pid
  end

  test "with the pool at 0 seats nothing goes, though today's plan would dispatch",
       %{account: account, first: first} do
    assert :idle = Autopilot.tick(enforcing_autopilot(account, 0, "5h ahead of its line"), 30_000)
    assert run_of(first.id) == nil
    assert Ash.get!(Issue, first.id).state == :queued

    # The reverse view is still recorded: today would have dispatched `first`.
    first_id = first.id

    assert [%{policy: "enforce", legacy_pick: ^first_id, walk_pick: nil}] =
             Ash.read!(AdmissionShadowEvent)
  end

  test "with room the walk's card goes; its run carries the reverse shadow",
       %{account: account, first: first} do
    assert {:ok, dispatched} =
             Autopilot.tick(enforcing_autopilot(account, 2, "5h room for 2"), 30_000)

    assert dispatched == first.id
    run = run_of(first.id)
    record = run.routing_decision["admission_shadow"]
    IO.puts("\n[e2e enforce] run #{run.id} admission_shadow: #{inspect(record)}")

    account_id = account.id

    assert %{
             "policy" => "enforce",
             "dispatched" => ^dispatched,
             "pick" => ^dispatched,
             "agrees" => true,
             "comparable" => true,
             "account_id" => ^account_id,
             "pool" => "claude",
             "node" => "local"
           } = record
  end
end
