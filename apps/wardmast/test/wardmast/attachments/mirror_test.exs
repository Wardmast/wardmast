defmodule Wardmast.Attachments.MirrorTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
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

    {:ok, ws} = Ash.create(Workspace, %{name: "mirror-ws", prefix: "mir"})
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ac"})
    {:ok, att} = Attachments.create(issue, %{data: Fixture.png()}, source: "worker")
    {:ok, issue: issue, att: att}
  end

  test "a ticket with no upstream ref has nothing to mirror to", %{issue: issue, att: att} do
    assert {:error, :not_supported} = Attachments.mirror(issue, att)
  end

  test "a pruned attachment has no bytes to mirror", %{issue: issue, att: att} do
    pruned = struct!(att, pruned_at: DateTime.utc_now())
    assert {:error, :pruned} = Attachments.mirror(%{issue | tracker_ref: "X-1"}, pruned)
  end

  test "an adapter without upload_attachment/2 is :not_supported, not a failure", %{
    issue: issue,
    att: att
  } do
    # The default tracker adapter implements none of the optional file callbacks.
    refute function_exported?(Wardmast.Trackers.for_task(issue), :upload_attachment, 2)

    assert {:error, :not_supported} =
             Wardmast.Trackers.upload_attachment(%{issue | tracker_ref: "X-1"}, %{
               filename: "a.png",
               content_type: att.content_type,
               data: "x"
             })
  end
end
