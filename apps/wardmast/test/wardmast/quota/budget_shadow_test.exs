defmodule Wardmast.Quota.BudgetShadowTest do
  @moduledoc """
  DC3 is shadow only (bd-6c8g4t; design §10, I1/I2/I8): the provider budget is
  computed and published, but nothing on an admission, gate, dispatch,
  scheduler or run-stopping path reads it. Until DC8 no dispatch decision may
  change, and these tests pin the construction.

  DC6 (bd-9ycsk4) adds one reader: `Wardmast.Board.WalkInputs`, the scheduler
  walk's capacity sets, which `Wardmast.Board.Snapshot.load/1` gathers on every load.
  The admission surfaces below still never name the budget.

  DC5 (bd-2c2a4g) adds the display readers: `Wardmast.Board.CapacityView`, the one
  read model behind the board's capacity strip, `scheduler_status` and
  `quota_get`. No admission surface, nor anything that stops a run, names
  `CapacityView`.

  DC8 (bd-30d5qo) makes the budget decide, through one module: `Wardmast.Accounts.SeatCheck`, the per-pool seat
  check. It is the only admission-path reader of the budget; the admission
  surfaces (`Admission`, `ResumeSlot`, provider and reviewer routing, the
  dispatch's hard-zero refusal) ask it and never name the budget themselves. I8 (design §11): the budget is read only by admission, the walk and
  the display; a budget change is handled only by the Autopilot, which plans a
  pass and stops nothing.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.Concurrency
  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Quota.Budget
  alias Wardmast.Quota.Budget.Server

  @lib Path.expand("../../../lib", __DIR__)

  # `Quota.Budget` itself (not `BudgetCalibration`, which DC2's test owns),
  # its server and inputs, or a call through an alias of any of them.
  @consumers ~r/Quota\.Budget(?!Calibration)\b|\bBudget\.(compute|publish|hysteresis|new_hysteresis|lowest|explore|expiring|Server|Inputs)\b/

  # The budget's own modules, the supervision tree that starts its server, the
  # scheduler walk's inputs (DC6) and the
  # seat check (DC8).
  # `quota/seat_weights.ex` (DC11) reads a published budget's window rates for the
  # weight floor; its callers are the seat check and the walk's inputs.
  # `quota/history.ex` only records the published figure on each snapshot row
  # (bd-9ntll1); it gates nothing. `loop/replay/admission.ex` (R15, bd-c7lx65)
  # reads `explore/2` to admit an operator-run offline replay into expiring
  # headroom; it gates only replays, never a dispatch, and
  # `Wardmast.Loop.ReplayIsolationTest` pins that no live path names it.
  @allowed ~w(
    wardmast/quota/budget.ex
    wardmast/quota/budget/server.ex
    wardmast/quota/budget/inputs.ex
    wardmast/quota/shadow_supervisor.ex
    wardmast/quota/history.ex
    wardmast/application.ex
    wardmast/board/walk_inputs.ex
    wardmast/board/capacity_view.ex
    wardmast/loop/replay/admission.ex
    wardmast/accounts/seat_check.ex
    wardmast/quota/seat_weights.ex
  )

  defp source_files(root) do
    root |> Path.join("**/*.{ex,exs}") |> Path.wildcard()
  end

  test "only the budget's own modules and the supervision tree name it" do
    offenders =
      @lib
      |> source_files()
      |> Enum.reject(&(Path.relative_to(&1, @lib) in @allowed))
      |> Enum.filter(&(File.read!(&1) =~ @consumers))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end

  test "neither the web app nor the CLI reads it yet" do
    for app <- ~w(wardmast_web wardmast_cli) do
      root = Path.expand("../../../../#{app}/lib", __DIR__)
      offenders = root |> source_files() |> Enum.filter(&(File.read!(&1) =~ @consumers))
      assert offenders == [], "#{app} reads the budget"
    end
  end

  test "the admission surfaces never name the budget or its published table" do
    surfaces = ~w(
      wardmast/accounts/admission.ex
      wardmast/accounts/concurrency.ex
      wardmast/accounts/slot_limit.ex
      wardmast/quota/gate.ex
      wardmast/board/autopilot.ex
      wardmast/board/scheduler.ex
      wardmast/board/snapshot.ex
      wardmast/workflows/dispatch_queue.ex
      wardmast/worker/dispatch.ex
      wardmast/worker/resume_slot.ex
      wardmast/agents/provider_routing.ex
      wardmast/agents/reviewer_routing.ex
      wardmast/nodes/placement.ex
      wardmast/nodes/capacity.ex
    )

    existing = for rel <- surfaces, File.exists?(Path.join(@lib, rel)), do: rel
    assert length(existing) > 8

    for rel <- existing do
      source = File.read!(Path.join(@lib, rel))
      refute source =~ @consumers, "#{rel} reads the provider budget"
      refute source =~ "CapacityView", "#{rel} reads the display view of the budgets"
      refute source =~ "arbiter_quota_budgets", "#{rel} reads the budget table"
    end
  end

  test "nothing that stops a run reads it (I8)" do
    stoppers = Path.join(@lib, "wardmast/worker/**/*.ex") |> Path.wildcard()
    assert stoppers != []
    assert Enum.filter(stoppers, &(File.read!(&1) =~ @consumers)) == []
    assert Enum.filter(stoppers, &(File.read!(&1) =~ "CapacityView")) == []
  end

  test "the budget reaches Pace only through the gate (I6)" do
    source = File.read!(Path.join(@lib, "wardmast/quota/budget.ex"))
    refute source =~ ~r/\bPace\./
    refute source =~ "alias Wardmast.Quota.Pace"
  end

  test "a published zero budget changes no account's headroom" do
    account = %ProviderAccount{id: Ecto.UUID.generate(), provider: :claude, max_concurrent: 3}
    before = Concurrency.account_headroom(account, nil)

    inputs = fn _calibration ->
      [%{account_id: account.id, account: account, pool: "claude", quota: nil, hard: :paused}]
    end

    table = :budget_shadow_table

    start_supervised!(
      {Server,
       name: :budget_shadow_server,
       table: table,
       inputs: inputs,
       enabled: true,
       tick_ms: :never,
       calibration: :never}
    )

    :ok = Server.recompute(:budget_shadow_server)
    assert %Budget{budget: 0, binding: :paused} = Server.get(account.id, "claude", nil, table)

    assert Concurrency.account_headroom(account, nil) == before
    assert Concurrency.limit(account, nil) == 3
  end

  # ---- I8 under enforce (DC8) -----------------------------------------------------

  test "the seat check is asked only by the admission surfaces (I8)" do
    callers =
      @lib
      |> source_files()
      |> Enum.filter(&(File.read!(&1) =~ ~r/\bSeatCheck\.(check|room\?|hard_zero|describe)\(/))
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.sort()

    assert callers ==
             Enum.sort(~w(
               wardmast/accounts/admission.ex
               wardmast/agents/provider_routing.ex
               wardmast/agents/reviewer_routing.ex
               wardmast/worker/dispatch.ex
               wardmast/worker/resume_slot.ex
             ))

    for app <- ~w(wardmast_web wardmast_cli) do
      root = Path.expand("../../../../#{app}/lib", __DIR__)
      assert Enum.filter(source_files(root), &(File.read!(&1) =~ "SeatCheck")) == []
    end
  end

  test "a budget change is handled only by the Autopilot, which plans a pass (I8)" do
    handlers =
      @lib
      |> source_files()
      |> Enum.filter(&(File.read!(&1) =~ "{:budget_changed"))
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.sort()

    # The server announces it; the Autopilot's handler only ever plans a pass
    # (`Wardmast.Board.AutopilotEnforceTest`: a fall plans nothing).
    assert handlers == ["wardmast/board/autopilot.ex", "wardmast/quota/budget/server.ex"]

    source = File.read!(Path.join(@lib, "wardmast/board/autopilot.ex"))

    [handler] =
      Regex.run(~r/def handle_info\(\{:budget_changed.*?\n  end\n/s, source)

    refute handler =~ ~r/Worker\.|stop|kill|fail/
    assert handler =~ "request_plan"
  end
end
