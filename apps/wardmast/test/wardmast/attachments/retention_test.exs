defmodule Wardmast.Attachments.RetentionTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
  alias Wardmast.Attachments.Retention
  alias Wardmast.Repo
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:wardmast, :attachments)
    Application.put_env(:wardmast, :attachments, root: dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardmast, :attachments, previous),
        else: Application.delete_env(:wardmast, :attachments)
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "ret-ws", prefix: "ret"})
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ac"})
    {:ok, issue: issue}
  end

  test "sweep/1 runs the age prune and the orphan sweep", %{issue: issue} do
    {:ok, _} = Attachments.create(issue, %{data: Fixture.png()}, source: "worker")

    closed_at = ~U[2026-01-01 00:00:00.000000Z]

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE issues SET state = 'closed', closed_at = ? WHERE id = ?",
      [DateTime.to_iso8601(closed_at), issue.id]
    )

    assert %{pruned: 1, purged: 0} = Retention.sweep(now: DateTime.add(closed_at, 91 * 86_400))
    assert %{pruned: 0, purged: 0} = Retention.sweep()
  end

  test "is not scheduled when disabled" do
    pid = start_supervised!({Retention, name: nil, enabled: false})
    assert %{enabled: false} = :sys.get_state(pid)
  end
end
