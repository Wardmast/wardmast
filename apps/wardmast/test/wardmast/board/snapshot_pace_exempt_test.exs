defmodule Wardmast.Board.SnapshotPaceExemptTest do
  @moduledoc """
  The P0 pace exemption on the board (bd-6bxv7h, design §4.2): the board-wide
  `quota_hold/2` evaluates with no task, so an exempt card gets its own
  verdict at the lifted ceiling — Autopilot promotes it past the paced line,
  holds it at the dedicated cap (and says "P0 exempt"), and with the layer off
  nothing changes. Real persisted account + snapshot, real clock.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Accounts.ProviderAccount
  alias Wardmast.Accounts.WorkspaceProviderAccount
  alias Wardmast.Board.Snapshot
  alias Wardmast.Quota.AnthropicQuota
  alias Wardmast.Quota.Gate
  alias Wardmast.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "pe-board-#{n}", prefix: "peb#{n}"})
    %{ws: ws, n: n}
  end

  # 5h window 30 minutes in: elapsed 0.10, so a paced account's line is the
  # 0.35 floor.
  defp quota_for!(ws, n, quota_config, used) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "peb-#{n}-#{System.unique_integer([:positive])}",
        quota_config: quota_config
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    quota =
      Ash.create!(AnthropicQuota, %{
        provider_account_id: account.id,
        provider: "claude",
        utilization_5h: used,
        status_5h: "allowed",
        reset_5h_at: DateTime.add(DateTime.utc_now(), 16_200, :second),
        captured_at: DateTime.utc_now()
      })

    {account, quota}
  end

  defp issue(ws, id, priority) do
    %{
      id: id,
      title: "Task #{id}",
      state: :queued,
      priority: priority,
      difficulty: 2,
      issue_type: :task,
      workspace_id: ws.id,
      description: nil,
      acceptance: nil,
      notes: nil,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  defp board(ws, issues),
    do: Snapshot.load(workspace_id: ws.id, issues: issues, workers: [], blocked_by: %{})

  defp reason(board, id), do: Enum.find(board.ready, &(&1.id == id)).reason

  @exempt %{
    "threshold_mode" => "paced",
    "pace_exempt_priority" => 0,
    "pace_exempt_threshold" => 0.8
  }

  test "an exempt P0 card is promoted past the paced line, ahead of a P2 card", %{ws: ws, n: n} do
    quota_for!(ws, n, @exempt, 0.40)

    assert board(ws, [issue(ws, "bd-p2", 2), issue(ws, "bd-p0", 0)]).promote == "bd-p0"
  end

  test "Throttle.check reads the task's own priority", %{ws: ws, n: n} do
    {account, quota} = quota_for!(ws, n, @exempt, 0.40)

    assert Gate.Throttle.check(%{priority: 0}, quota, ws, account: account) == :allow

    assert {:hold, %{phrase: phrase}} =
             Gate.Throttle.check(%{priority: 2}, quota, ws, account: account)

    assert phrase =~ "ahead of pace"
    assert {:hold, _} = Gate.Throttle.check(nil, quota, ws, account: account)
  end

  test "Throttle.check holds a P0 at the dedicated cap with the exempt phrase", %{ws: ws, n: n} do
    {account, quota} = quota_for!(ws, n, @exempt, 0.85)

    assert {:hold, %{mode: :exempt, threshold: 0.8, phrase: phrase}} =
             Gate.Throttle.check(%{priority: 0}, quota, ws, account: account)

    assert phrase =~ "P0 exempt"
  end
end
