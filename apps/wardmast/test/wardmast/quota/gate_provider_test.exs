defmodule Wardmast.Quota.GateProviderTest do
  @moduledoc """
  Provider-aware dispatch gating (bd-2mpo3f).

  Before this, `Wardmast.Quota.Gate` read only the Anthropic snapshot, so a
  Codex / Gemini / Antigravity worker was dispatched even when that provider was
  out of quota. These specs pin the normalized snapshot (`Gate.Snapshot`), the
  per-provider snapshot lookup (`Quota.latest_for_workspace/2`), and the
  end-to-end hold through `Dispatch.dispatch/2` for an over-quota Codex account.
  """
  use Wardmast.DataCase, async: false

  # bd-asxw4e: the tickets here are created in Backlog and dispatched straight
  # away, which a dispatch refuses unless forced — so these calls pass
  # `force: true`. What a dispatch admits is `DispatchEligibilityTest`'s.

  alias Wardmast.Quota
  alias Wardmast.Quota.AnthropicQuota
  alias Wardmast.Quota.CodexQuota
  alias Wardmast.Quota.Gate
  alias Wardmast.Quota.Gate.Snapshot
  alias Wardmast.Quota.GoogleQuota
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker
  alias Wardmast.Workflows.DispatchQueue
  alias Wardmast.Workflows.DispatchQueueSupervisor

  defp ws(config \\ %{}), do: %Workspace{id: "ws-x", config: config}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp ahead(secs),
    do: DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.truncate(:second)

  defp behind(secs), do: ahead(-secs)

  # `ProcessTeardown.stop_child/2`, never `GenServer.stop/3` (bd-2l0hzm): a
  # DispatchQueue is a `:permanent` child, so a plain stop is a restart that
  # counts toward `DispatchQueueSupervisor`'s intensity (3 in 5s). Four such
  # stops close together shut the supervisor down, and the `DataCase` sweep
  # that ran next hit `:noproc`.
  # `Quota.provider_code(:gemini)` probes PATH live, and with the upstream
  # Gemini CLI provider gone (bd-ac53wz) it resolves to nothing unless `agy`
  # is there — pin a stub so the gate reads the antigravity row regardless of
  # whether this host has `agy` installed.
  defp pin_agy_on_path do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arbiter-dispatch-hint-stub-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    old_path = System.get_env("PATH") || ""
    agy_path = Path.join(tmp, "agy")
    File.write!(agy_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(agy_path, 0o755)
    System.put_env("PATH", tmp <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(tmp)
    end)
  end

  defp stop_dispatch_queue(workspace_id) do
    if pid = DispatchQueueSupervisor.whereis(workspace_id) do
      Wardmast.ProcessTeardown.stop_child(DispatchQueueSupervisor, pid)
    end
  end

  defp codex_quota(attrs) do
    %CodexQuota{provider_account_id: "acct-x", provider: "codex", captured_at: now()}
    |> struct(attrs)
  end

  defp google_quota(attrs) do
    %GoogleQuota{provider_account_id: "acct-x", provider: "antigravity", captured_at: now()}
    |> struct(attrs)
  end

  # A synthetic Antigravity row with a persisted per-bucket `models` list, in
  # the same shape `Wardmast.Quota.CloudCode.antigravity/1` writes (bd-7qj58o).
  defp antigravity_quota(models) do
    %GoogleQuota{
      provider_account_id: "acct-x",
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(3600),
      snapshot: %{"models" => models}
    }
  end

  defp agy_bucket(group, window, remaining_percentage, reset_at) do
    %{
      "model_id" => "#{group}_#{window}",
      "remaining_percentage" => remaining_percentage,
      "reset_at" => reset_at && DateTime.to_iso8601(reset_at)
    }
  end

  describe "Gate.Snapshot.normalize/1" do
    test "nil normalizes to nil (fail-open)" do
      assert Snapshot.normalize(nil) == nil
    end

    test "Anthropic maps the 5h window onto the primary slot" do
      reset = ahead(3600)

      s =
        Snapshot.normalize(%AnthropicQuota{
          provider_account_id: "acct-x",
          provider: "claude",
          status_5h: "allowed",
          utilization_5h: 0.42,
          reset_5h_at: reset,
          overage_status: "in_overage",
          captured_at: now()
        })

      assert s.provider == "claude"
      assert s.utilization == 0.42
      assert s.status == "allowed"
      assert s.reset_at == reset
      assert s.overage_status == "in_overage"
    end

    test "Codex maps the session window and rescales used-percent to a fraction" do
      reset = ahead(3600)

      s =
        Snapshot.normalize(
          codex_quota(%{
            session_used_percent: 92.0,
            session_reset_at: reset,
            limit_reached: false
          })
        )

      assert s.provider == "codex"
      assert_in_delta s.utilization, 0.92, 0.0001
      assert s.reset_at == reset
      # limit_reached: false is plan-allowed, so the status must not read as
      # "not allowed" (which would hold every dispatch).
      refute Gate.over_cap?(
               codex_quota(%{session_used_percent: 10.0, limit_reached: false}),
               ws()
             )
    end

    test "Codex limit_reached surfaces as a not-allowed status" do
      s = Snapshot.normalize(codex_quota(%{limit_reached: true}))
      assert s.status != nil
      assert s.status != "allowed"
    end

    test "Codex labels windows from their stored length; free's 30d window paces" do
      s = Snapshot.normalize(codex_quota(%{session_window_minutes: 43_200}))
      assert s.window_label == "30d"
      assert Gate.window_seconds(s.window_label) == 2_592_000

      s =
        Snapshot.normalize(
          codex_quota(%{session_window_minutes: 300, weekly_window_minutes: 10_080})
        )

      assert {s.window_label, s.secondary_window_label} == {"5h", "weekly"}

      s = Snapshot.normalize(codex_quota(%{session_window_minutes: 90}))
      assert s.window_label == "90m"
      assert Gate.window_seconds("90m") == 5_400
    end

    test "Codex with no stored length keeps the legacy session/weekly labels" do
      s = Snapshot.normalize(codex_quota(%{}))
      assert {s.window_label, s.secondary_window_label} == {"session", "weekly"}
      assert Gate.window_seconds("session") == nil
    end

    test "Google maps the representative used-percent onto the primary slot" do
      s = Snapshot.normalize(google_quota(%{used_percent: 95.0, reset_at: ahead(600)}))

      assert s.provider == "antigravity"
      assert_in_delta s.utilization, 0.95, 0.0001
    end
  end

  describe "Gate.Throttle.check/4 — Codex" do
    test "holds when the session window is at/over the threshold" do
      assert {:hold, reason} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{session_used_percent: 92.0, session_reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert reason.provider == "codex"
    end

    test "holds when Codex reports limit_reached even at low utilization" do
      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{
                   session_used_percent: 3.0,
                   session_reset_at: ahead(3600),
                   limit_reached: true
                 }),
                 ws(),
                 []
               )
    end

    test "allows when there is headroom" do
      assert Gate.Throttle.check(
               nil,
               codex_quota(%{session_used_percent: 12.0, session_reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end

    test "stale snapshot (session window already reset) fails open" do
      assert Gate.Throttle.check(
               nil,
               codex_quota(%{
                 session_used_percent: 99.0,
                 session_reset_at: behind(60),
                 limit_reached: true
               }),
               ws(),
               []
             ) == :allow
    end

    test "respects a per-workspace threshold override" do
      w = ws(%{"quota" => %{"throttle_threshold" => 0.5}})

      assert {:hold, _} =
               Gate.Throttle.check(
                 nil,
                 codex_quota(%{session_used_percent: 60.0, session_reset_at: ahead(3600)}),
                 w,
                 []
               )
    end
  end

  describe "Gate.Throttle.check/4 — Google (Antigravity, collapsed representative figure)" do
    test "holds when the representative model is at/over the threshold" do
      assert {:hold, reason} =
               Gate.Throttle.check(
                 nil,
                 google_quota(%{used_percent: 97.0, reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert reason.provider == "antigravity"
    end

    test "allows when there is headroom" do
      assert Gate.Throttle.check(
               nil,
               google_quota(%{used_percent: 5.0, reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end

    test "stale snapshot fails open" do
      assert Gate.Throttle.check(
               nil,
               google_quota(%{used_percent: 99.0, reset_at: behind(60)}),
               ws(),
               []
             ) == :allow
    end
  end

  describe "Gate.Throttle.check/4 — Antigravity sub-buckets (bd-7qj58o AC3/AC4)" do
    test "holds when the 5h bucket is at/over cap" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 3.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 50.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 90.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 90.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "5h"
      assert reason.provider == "antigravity"
    end

    test "holds on the weekly bucket per the existing long-window rule, even with 5h headroom" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 90.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 5.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 90.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 90.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "weekly"
    end

    test "allows when every bucket has headroom" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 80.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert Gate.Throttle.check(nil, quota, ws(), []) == :allow
    end

    test "a claude-*/gpt-* model gates on the \"Claude and GPT models\" bucket, not Gemini's" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 3.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 3.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 80.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      # The Gemini Models bucket is blown, but this dispatch is routed to a
      # claude-* model — it must read the healthy Claude/GPT bucket, not the
      # unrelated Gemini one.
      assert Gate.Throttle.check(nil, quota, ws(), model: "claude-opus-4-6-thinking") == :allow
    end

    test "a gpt-* model also gates on the \"Claude and GPT models\" bucket" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), model: "gpt-5.1")
      assert reason.window == "5h"
    end

    test "a gemini-* model gates on the \"Gemini Models\" bucket, not Claude/GPT's" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 3.0, ahead(86_400))
        ])

      assert Gate.Throttle.check(nil, quota, ws(), model: "gemini-3.8-flash-medium") == :allow
    end

    test "with no model hint, gates conservatively on the worst of both groups" do
      quota =
        antigravity_quota([
          agy_bucket("gemini_models", "5h", 80.0, ahead(3600)),
          agy_bucket("gemini_models", "weekly", 80.0, ahead(86_400)),
          agy_bucket("claude_and_gpt_models", "5h", 3.0, ahead(3600)),
          agy_bucket("claude_and_gpt_models", "weekly", 80.0, ahead(86_400))
        ])

      assert {:hold, _} = Gate.Throttle.check(nil, quota, ws(), [])
    end

    test "a snapshot with no parseable buckets falls back to the representative figure" do
      quota = antigravity_quota([]) |> struct(used_percent: 97.0, reset_at: ahead(3600))

      assert {:hold, reason} = Gate.Throttle.check(nil, quota, ws(), [])
      assert reason.window == "used"
    end
  end

  describe "Gate.Continue.check/4 — non-Anthropic providers" do
    test "tags overage when Codex is past its cap" do
      assert {:overage, spend} =
               Gate.Continue.check(
                 nil,
                 codex_quota(%{limit_reached: true, session_reset_at: ahead(3600)}),
                 ws(),
                 []
               )

      assert is_float(spend)
    end

    test "does not tag overage merely at the throttle threshold" do
      assert Gate.Continue.check(
               nil,
               codex_quota(%{session_used_percent: 99.0, session_reset_at: ahead(3600)}),
               ws(),
               []
             ) == :allow
    end
  end

  describe "Quota.latest_for_workspace/2 (P5: resolves the workspace to its account)" do
    setup do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "lfp-#{System.unique_integer([:positive])}",
          prefix: "lf#{System.unique_integer([:positive])}"
        })

      {:ok, workspace: workspace}
    end

    test "reads each provider from its own table", %{workspace: workspace} do
      Ash.create!(AnthropicQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "claude"),
        provider: "claude",
        utilization_5h: 0.1,
        captured_at: now()
      })

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 91.0,
        captured_at: now()
      })

      Ash.create!(GoogleQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "antigravity"),
        provider: "antigravity",
        used_percent: 77.0,
        captured_at: now()
      })

      assert %AnthropicQuota{} = Quota.latest_for_workspace(workspace.id, :claude)

      assert %CodexQuota{session_used_percent: 91.0} =
               Quota.latest_for_workspace(workspace.id, :codex)

      assert %GoogleQuota{used_percent: 77.0} =
               Quota.latest_for_workspace(workspace.id, :antigravity)

      # `:gemini` resolves dynamically (bd-7qj58o) to the agy code when `agy`
      # is on this host's PATH, and — since bd-ac53wz dropped the upstream
      # Gemini CLI provider — to no tracked quota otherwise.
      case Quota.provider_code(:gemini) do
        "antigravity" ->
          assert %GoogleQuota{used_percent: 77.0} =
                   Quota.latest_for_workspace(workspace.id, :gemini)

        nil ->
          assert Quota.latest_for_workspace(workspace.id, :gemini) == nil
      end

      assert Quota.latest_for_workspace(workspace.id, :gemini_cli) == nil
      assert Quota.latest_for_workspace(workspace.id, :nonesuch) == nil
    end
  end

  describe "Dispatch.dispatch/2 — Codex over quota" do
    setup do
      # The Codex/Google snapshots come from the CloudProbe, not the Anthropic
      # proxy, so leave the proxy at its test default (disabled) to prove the
      # non-Anthropic gate does not depend on it.
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "cxg-#{System.unique_integer([:positive])}",
          prefix: "cx#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => "codex"},
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex work", workspace_id: workspace.id})

      on_exit(fn -> stop_dispatch_queue(workspace.id) end)

      {:ok, workspace: workspace, task: task}
    end

    test "a paused provider holds the dispatch: held — codex paused: <reason> (bd-5ef587)", %{
      workspace: workspace,
      task: task
    } do
      {:ok, _} = Wardmast.Providers.Pause.pause("codex", reason: "jail escape", by: "test")

      assert {:error, {:quota_held, held_id}} =
               Wardmast.Worker.Dispatch.dispatch(task.id, force: true, start_driver: false)

      assert held_id == task.id
      assert Worker.whereis(task.id) == nil
      assert DispatchQueue.held?(workspace.id, task.id)

      assert Enum.any?(
               DispatchQueue.state(DispatchQueueSupervisor.whereis(workspace.id)).items,
               &(DispatchQueue.reason_text(&1.reason) == "held — codex paused: jail escape")
             )
    end

    test "a healthy Codex snapshot lets the dispatch through", %{
      workspace: workspace,
      task: task
    } do
      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 4.0,
        session_reset_at: ahead(3600),
        limit_reached: false,
        captured_at: now()
      })

      assert {:ok, result} =
               Wardmast.Worker.Dispatch.dispatch(task.id,
                 force: true,
                 repo: "r",
                 start_driver: false
               )

      assert result.task.state == :active
    end

    test "an over-quota Anthropic snapshot does NOT hold a Codex dispatch", %{
      workspace: workspace,
      task: task
    } do
      # Anthropic is blown, Codex has headroom — the Codex worker must still run.
      Ash.create!(AnthropicQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "claude"),
        provider: "claude",
        status_5h: "rejected",
        utilization_5h: 0.99,
        reset_5h_at: ahead(3600),
        captured_at: now()
      })

      Ash.create!(CodexQuota, %{
        provider_account_id: quota_account_id!(workspace.id, "codex"),
        provider: "codex",
        session_used_percent: 4.0,
        session_reset_at: ahead(3600),
        captured_at: now()
      })

      assert {:ok, result} =
               Wardmast.Worker.Dispatch.dispatch(task.id,
                 force: true,
                 repo: "r",
                 start_driver: false
               )

      assert result.task.state == :active
    end


  describe "Dispatch.dispatch/2 — Antigravity model-hint threading (bd-7qj58o AC4)" do
    # These drive the gate through `Quota.provider_code(:gemini)`, which
    # probes PATH live — pin `agy` onto PATH (mirrors
    # `provider_code_gemini_test.exs`) so the antigravity row these tests
    # seed is actually the one the gate looks up, regardless of whether this
    # host happens to have `agy` installed.
    setup do
      pin_agy_on_path()

      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "agyh-#{System.unique_integer([:positive])}",
          prefix: "ah#{System.unique_integer([:positive])}",
          config: %{
            "agent" => %{"type" => "gemini", "config" => %{"model_tier" => "premium"}},
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{"P0" => %{"model" => "claude-opus-4-6-thinking"}}
            },
            "quota" => %{"on_exhaustion" => "throttle"}
          }
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "agy flagship work",
          workspace_id: workspace.id,
          priority: 0
        })

      on_exit(fn -> stop_dispatch_queue(workspace.id) end)

      {:ok, workspace: workspace, task: task}
    end


  # bd-a14qd1 moved these off the removed `Workflows.QuotaGate.Default` and
  # onto `Board.Snapshot.quota_hold/1`, the board scheduler's own gate. It
  # resolves the provider account and provider from the asking workspace, so
  # the per-provider keying these tests pin is unchanged.
  describe "Board.Snapshot.quota_hold/1 — provider-aware cap clamp" do
    defp hold(workspace), do: Wardmast.Board.Snapshot.quota_hold(workspace.id)

    defp provider_workspace(type) do
      {:ok, workspace} =
        Ash.create(Workspace, %{
          name: "qgd-#{System.unique_integer([:positive])}",
          prefix: "qg#{System.unique_integer([:positive])}",
          config: %{"agent" => %{"type" => type}}
        })

      workspace
    end


  describe "DispatchQueue drain — per-provider snapshots" do

  defmodule RecordingDispatcher do
    @moduledoc false
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:wardmast, :test_dispatch_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end
end
