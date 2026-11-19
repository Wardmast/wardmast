defmodule Wardmast.Worker.DispatchEnforceTest do
  @moduledoc """
  `Dispatch.dispatch/2` under seat admission (DC8, design
  `provider-dynamic-concurrency.md` §4.4, §4.5, §7, E9):

    * **The seat check (AC1).** A fresh dispatch is admitted while the seats on
      its pool are below `min(budget, max_concurrent, share)`.
    * **No pace hold for a fresh dispatch.** The gate keeps only its hard rules
      (`pace: false`): an account past its paced line still admits while its
      pool has a seat. A hard rule refuses a fresh dispatch as a hard zero on its
      pool — it waits in Ready, and nothing is queued in the `DispatchQueue`.
    * **The planned pair.** The walk's `planned: %{account_id, pool, node}`
      rides in, and routing takes the planned account while it is available.

  The published budgets come in through the `:seat_opts` seam: the test env's
  `Budget.Server` computes nothing. Every agent binary is stubbed by
  `Wardmast.TestSandbox`.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Wardmast.Quota.{AnthropicQuota, Budget, CodexQuota}
  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.TestSandbox
  alias Wardmast.Worker.Dispatch
  alias Wardmast.Workers.Run
  alias Wardmast.Workflows.DispatchQueue

  require Ash.Query

  @repo "en/repo"

  setup do
    claude_credential_env!()

    sandbox = TestSandbox.provision!("dispatch-enforce")
    put_app_env(:wardmast, :worktree_root, sandbox.worktree_root)
    put_app_env(:wardmast, :repo_paths, %{@repo => sandbox.repo})
    Wardmast.Test.ResumeSlotFixture.put_local_cap(10)

    on_exit(fn ->
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
      TestSandbox.own_live_workers!(sandbox)
    end)

    %{sandbox: sandbox}
  end

  # ---- fixtures -------------------------------------------------------------

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "en-#{System.unique_integer([:positive])}",
      prefix: "en#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp account!(provider, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{provider}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp link!(ws, account, position \\ 0) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  # 5h window `used`, `elapsed` of it gone; the 7d window quiet.
  defp claude_quota!(account, used, opts \\ []) do
    elapsed = Keyword.get(opts, :elapsed, 0.02)

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: used,
      reset_5h_at: DateTime.add(now(), round((1 - elapsed) * 18_000), :second),
      status_5h: Keyword.get(opts, :status, "allowed"),
      utilization_7d: 0.0,
      reset_7d_at: DateTime.add(now(), 302_400, :second),
      status_7d: "allowed",
      captured_at: now()
    })
  end

  defp budget(account, n) do
    %Budget{
      account: account.id,
      pool: "claude",
      budget: n,
      binding: {:window, "5h"},
      reason: "5h binds",
      ceiling: %{max_concurrent: account.max_concurrent, share: nil}
    }
  end

  defp task!(ws, title \\ "fresh work"),
    do: Ash.create!(Issue, %{title: title, workspace_id: ws.id})

  defp dispatch(task, opts \\ []),
    do: Dispatch.dispatch(task.id, [force: true, repo: @repo, start_driver: false] ++ opts)

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(base_task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  # ---- the seat check (AC1) ---------------------------------------------------

  describe "the seat check (AC1)" do
    setup %{sandbox: sandbox} do
      ws = workspace!()
      account = account!(:claude, %{max_concurrent: 3})
      link!(ws, account)

      # One live run already seated on the pool: 1 of max_concurrent 3.
      {:ok, live} = dispatch(task!(ws, "already running"))
      TestSandbox.own!(sandbox, live.worker_pid)

      %{ws: ws, account: account}
    end

    test "refused when the pool's seats reach its budget, though max_concurrent has room",
         ctx do
      task = task!(ctx.ws)

      assert {:error, {:account_at_capacity, info}} =
               dispatch(task, seat_opts: [budgets: [budget(ctx.account, 1)]])

      assert %{pool: "claude", cap: 1, holders: [_]} = info
      assert Ash.get!(Issue, task.id).state != :active
    end

    test "admitted while the pool has a free seat", ctx do
      task = task!(ctx.ws)

      assert {:ok, %{worker_pid: pid}} =
               dispatch(task, seat_opts: [budgets: [budget(ctx.account, 2)]])

      TestSandbox.own!(ctx.sandbox, pid)
      assert Ash.get!(Issue, task.id).state == :active
    end
  end

  # ---- the gate under enforce (§4.5, E9) ---------------------------------------

  describe "the gate" do
    setup do
      ws = workspace!()
      account = account!(:claude, %{quota_config: %{"threshold_mode" => "paced"}})
      link!(ws, account)
      %{ws: ws, account: account}
    end

    test "the same dispatch goes ahead — the seat check decides, not the line", ctx do
      claude_quota!(ctx.account, 0.40)
      task = task!(ctx.ws)

      assert {:ok, %{worker_pid: pid}} =
               dispatch(task, seat_opts: [budgets: [budget(ctx.account, 2)]])

      TestSandbox.own!(ctx.sandbox, pid)
      refute DispatchQueue.held?(ctx.ws.id, task.id)
    end

    test "a hard rule refuses a fresh dispatch as a hard zero, and queues nothing",
         ctx do
      claude_quota!(ctx.account, 0.10, status: "rejected")
      task = task!(ctx.ws)

      assert {:error, {:account_at_capacity, %{cap: 0, seat: seat} = info}} =
               dispatch(task, seat_opts: [budgets: [budget(ctx.account, 2)]])

      assert %{limit: 0, pool: "claude"} = seat
      message = Wardmast.Accounts.Admission.refusal_message(info)
      assert message =~ "quota exhausted"
      assert message =~ "--force-quota"
      refute message =~ "--over-cap"
      refute message =~ "over_cap"
      refute DispatchQueue.held?(ctx.ws.id, task.id)
      assert Ash.get!(Issue, task.id).state != :active
    end
  end

  # ---- the planned pair (§4.4) ---------------------------------------------------

  describe "the planned pair" do
    setup do
      ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})
      claude = account!(:claude)
      codex = account!(:codex)
      link!(ws, claude, 0)
      link!(ws, codex, 1)
      # Codex has the most headroom, so routing alone would pick it.
      claude_quota!(claude, 0.70, elapsed: 0.5)

      Ash.create!(CodexQuota, %{
        provider_account_id: codex.id,
        provider: "codex",
        session_used_percent: 10.0,
        session_reset_at: DateTime.add(now(), 3_600, :second),
        weekly_used_percent: 0.0,
        weekly_reset_at: DateTime.add(now(), 302_400, :second),
        limit_reached: false,
        captured_at: now()
      })

      %{ws: ws, claude: claude, codex: codex}
    end

    test "routing takes the planned account while it is available", ctx do
      task = task!(ctx.ws)
      planned = %{account_id: ctx.claude.id, pool: "claude", node: "local"}

      assert {:ok, %{worker_pid: pid}} = dispatch(task, planned: planned)
      TestSandbox.own!(ctx.sandbox, pid)

      decision = latest_run(task.id).routing_decision
      assert decision["account_id"] == ctx.claude.id
      assert decision["outcome"] == "planned"
    end

    test "without a plan, routing picks the most headroom as it does today", ctx do
      task = task!(ctx.ws)

      assert {:ok, %{worker_pid: pid}} = dispatch(task)
      TestSandbox.own!(ctx.sandbox, pid)
      assert latest_run(task.id).routing_decision["account_id"] == ctx.codex.id
    end

    test "a planned account that is no longer available is passed over", ctx do
      task = task!(ctx.ws)
      planned = %{account_id: Ecto.UUID.generate(), pool: "claude", node: "local"}

      assert {:ok, %{worker_pid: pid}} = dispatch(task, planned: planned)
      TestSandbox.own!(ctx.sandbox, pid)
      assert latest_run(task.id).routing_decision["account_id"] == ctx.codex.id
    end

    test "a held intent drops the plan: the drain re-plans" do
      opts = [
        planned: %{account_id: "a", pool: "claude", node: "local"}
      ]

      unrouted = Dispatch.unroute(opts)
      refute Keyword.has_key?(unrouted, :planned)
    end
  end
end
