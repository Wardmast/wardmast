defmodule Wardmast.AttachmentsTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
  alias Wardmast.Attachments.Attachment
  alias Wardmast.Repo
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:wardmast, :attachments)

    Application.put_env(:wardmast, :attachments, root: dir)
    on_exit(fn -> restore(previous) end)

    {:ok, ws} = Ash.create(Workspace, %{name: "att-ws", prefix: "att"})
    issue = make_issue(ws, "has attachments")
    {:ok, ws: ws, issue: issue, root: dir}
  end

  defp restore(nil), do: Application.delete_env(:wardmast, :attachments)
  defp restore(value), do: Application.put_env(:wardmast, :attachments, value)

  defp put_limits(overrides) do
    current = Application.get_env(:wardmast, :attachments, [])
    Application.put_env(:wardmast, :attachments, Keyword.merge(current, overrides))
  end

  defp make_issue(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ac"})
    issue
  end

  defp attach(issue, data, attrs \\ %{}, source \\ "worker") do
    Attachments.create(issue, Map.put(attrs, :data, data), source: source)
  end

  describe "create/3" do
    test "stores the bytes content-addressed and records the metadata", %{
      issue: issue,
      root: root,
      ws: ws
    } do
      data = Fixture.png(640, 480)

      assert {:ok, %Attachment{} = att} =
               attach(issue, data, %{filename: "home.png", caption: "Home page"})

      assert att.task_id == issue.id
      assert att.workspace_id == ws.id
      assert att.content_type == "image/png"
      assert att.byte_size == byte_size(data)
      assert {att.width, att.height} == {640, 480}
      assert att.source == "worker"
      assert att.sha256 == Base.encode16(:crypto.hash(:sha256, data), case: :lower)
      assert att.filename == "home.png"
      assert is_nil(att.pruned_at)

      sha = att.sha256
      path = Path.join([root, ws.id, String.slice(sha, 0, 2), "#{sha}.png"])
      assert File.read!(path) == data
      assert {:ok, ^data} = Attachments.read_blob(att)
    end

    test "the type is sniffed from the bytes, not from the filename", %{issue: issue} do
      assert {:ok, %{content_type: "image/jpeg"}} =
               attach(issue, Fixture.jpeg(), %{filename: "shot.png"})

      assert {:error, {:invalid, message, %{reason: "unsupported_type"}}} =
               attach(issue, "<svg xmlns='http://www.w3.org/2000/svg'/>", %{filename: "x.png"})

      assert message =~ "png"
    end

    test "refuses an image over the per-image byte limit and stores nothing", %{issue: issue} do
      put_limits(max_image_bytes: 1_000)

      assert {:error, {:invalid, _, %{reason: "too_large", limit: 1_000}}} =
               attach(issue, Fixture.png(4, 3, bytes: 1_001))

      assert Attachments.list(issue.id) == []
      # Exactly at the limit is accepted.
      assert {:ok, _} = attach(issue, Fixture.png(4, 3, bytes: 1_000))
    end

    test "the design's default per-image limit is 2 MiB", %{issue: issue} do
      assert Attachments.limits().max_image_bytes == 2_097_152

      assert {:error, {:invalid, _, %{reason: "too_large"}}} =
               attach(issue, Fixture.png(4, 3, bytes: 2_097_153))

      assert {:ok, _} = attach(issue, Fixture.png(4, 3, bytes: 2_097_152))
    end

    test "refuses an image wider than 3840 px or taller than 8000 px", %{issue: issue} do
      assert {:error, {:invalid, _, %{reason: "dimensions"}}} =
               attach(issue, Fixture.png(3841, 100))

      assert {:error, {:invalid, _, %{reason: "dimensions"}}} =
               attach(issue, Fixture.png(100, 8001))

      assert {:ok, _} = attach(issue, Fixture.png(3840, 8000))
    end

    test "caps the files and the bytes on one ticket", %{issue: issue} do
      put_limits(max_ticket_files: 2)
      assert {:ok, _} = attach(issue, Fixture.png(4, 3, salt: "a"))
      assert {:ok, _} = attach(issue, Fixture.png(4, 3, salt: "b"))

      assert {:error, {:conflict, _, %{reason: "ticket_file_limit"}}} =
               attach(issue, Fixture.png(4, 3, salt: "c"))

      put_limits(max_ticket_files: 200, max_ticket_bytes: byte_size(Fixture.png()) * 2)

      assert {:error, {:conflict, _, %{reason: "ticket_byte_limit"}}} =
               attach(issue, Fixture.png(4, 3, salt: "d"))
    end

    test "the global cap refuses when nothing prunable remains", %{issue: issue} do
      put_limits(max_total_bytes: byte_size(Fixture.png(4, 3, salt: "x")))
      assert {:ok, _} = attach(issue, Fixture.png(4, 3, salt: "x"))

      # Open tickets are never pruned to make room.
      assert {:error, {:conflict, _, %{reason: "global_limit"}}} =
               attach(issue, Fixture.png(4, 3, salt: "y"))
    end

    test "the global cap prunes a closed ticket's blobs, oldest first, to make room", ctx do
      %{issue: issue, ws: ws, root: root} = ctx
      closed = make_issue(ws, "closed one")
      {:ok, old} = attach(closed, Fixture.png(4, 3, salt: "old"))
      close!(closed)

      size = byte_size(Fixture.png(4, 3, salt: "old"))
      put_limits(max_total_bytes: size)

      assert {:ok, fresh} = attach(issue, Fixture.png(4, 3, salt: "new"))
      assert Repo.get!(Attachment, old.id).pruned_at
      refute File.exists?(blob_path(root, old))
      assert File.exists?(blob_path(root, fresh))
    end

    test "only Arbiter may write the arbiter-capture source", %{issue: issue} do
      assert {:error, {:forbidden, _}} = attach(issue, Fixture.png(), %{}, "arbiter-capture")
      assert {:error, {:invalid, _}} = attach(issue, Fixture.png(), %{}, "somebody")

      assert {:ok, %{source: "arbiter-capture", capture_id: "cap-1", head_sha: "abc"}} =
               Attachments.create_capture(issue, %{
                 data: Fixture.png(),
                 capture_id: "cap-1",
                 head_sha: "abc",
                 base_sha: "def",
                 shot_id: "home",
                 viewport: "desktop",
                 theme: "light",
                 role: "after"
               })
    end

    test "the same bytes attached twice share one blob", %{issue: issue, root: root} do
      data = Fixture.png()
      {:ok, a} = attach(issue, data)
      {:ok, b} = attach(issue, data)
      assert a.id != b.id
      assert blob_path(root, a) == blob_path(root, b)
      assert length(Path.wildcard(Path.join([root, "**", "*.png"]))) == 1
    end

    test "role must be before or after", %{issue: issue} do
      assert {:error, {:invalid, _}} = attach(issue, Fixture.png(), %{role: "during"})
      assert {:ok, %{role: "before"}} = attach(issue, Fixture.png(), %{role: "before"})
    end
  end

  describe "list/1 and pairs/1" do
    test "lists oldest first and pairs before/after by shot, viewport and theme", %{issue: issue} do
      {:ok, a} = attach(issue, Fixture.png(4, 3, salt: "1"), %{role: "before", shot_id: "home"})
      {:ok, b} = attach(issue, Fixture.png(4, 3, salt: "2"), %{role: "after", shot_id: "home"})
      {:ok, c} = attach(issue, Fixture.png(4, 3, salt: "3"), %{caption: "loose"})
      {:ok, d} = attach(issue, Fixture.png(4, 3, salt: "4"), %{role: "after", shot_id: "lonely"})

      listed = Attachments.list(issue.id)
      assert Enum.map(listed, & &1.id) == [a.id, b.id, c.id, d.id]

      assert [
               %{kind: :pair, before: %{id: a_id}, after: %{id: b_id}},
               %{kind: :single, attachment: %{id: c_id}},
               %{kind: :single, attachment: %{id: d_id}}
             ] = Attachments.pairs(listed)

      assert {a_id, b_id, c_id, d_id} == {a.id, b.id, c.id, d.id}
    end
  end

  describe "retention" do
    test "a hard-deleted ticket's attachments and blobs are swept", ctx do
      %{issue: issue, root: root} = ctx
      {:ok, att} = attach(issue, Fixture.png(4, 3, salt: "gone"))
      assert File.exists?(blob_path(root, att))

      hard_delete!(issue)
      assert %{purged: 1} = Attachments.sweep_orphans()

      assert Attachments.list(issue.id) == []
      refute File.exists?(blob_path(root, att))
      # Idempotent.
      assert %{purged: 0} = Attachments.sweep_orphans()
    end

    test "sweeping a deleted ticket keeps a blob another ticket still references", ctx do
      %{issue: issue, ws: ws, root: root} = ctx
      other = make_issue(ws, "shares the image")
      data = Fixture.png(4, 3, salt: "shared")
      {:ok, mine} = attach(issue, data)
      {:ok, _theirs} = attach(other, data)

      hard_delete!(issue)
      Attachments.sweep_orphans()

      assert File.exists?(blob_path(root, mine))
      assert [_] = Attachments.list(other.id)
    end

    test "purge_task/1 removes one ticket's rows and blobs immediately", ctx do
      %{issue: issue, root: root} = ctx
      {:ok, att} = attach(issue, Fixture.png(4, 3, salt: "now"))

      assert :ok = Attachments.purge_task(issue.id)
      assert Attachments.list(issue.id) == []
      refute File.exists?(blob_path(root, att))
    end

    test "prune_expired/1 deletes the blob 90 days after close but keeps the row", ctx do
      %{issue: issue, root: root} = ctx
      {:ok, att} = attach(issue, Fixture.png(4, 3, salt: "p"), %{caption: "kept"})
      closed_at = close!(issue)

      # Day 89: nothing happens.
      now = DateTime.add(closed_at, 89 * 86_400)
      assert %{pruned: 0} = Attachments.prune_expired(now: now)
      assert File.exists?(blob_path(root, att))

      # Day 91: the blob goes, the row stays with its provenance and hash.
      now = DateTime.add(closed_at, 91 * 86_400)
      assert %{pruned: 1} = Attachments.prune_expired(now: now)

      pruned = Repo.get!(Attachment, att.id)
      assert %DateTime{} = pruned.pruned_at
      assert pruned.sha256 == att.sha256
      assert pruned.caption == "kept"
      refute File.exists?(blob_path(root, att))
      assert {:error, :pruned} = Attachments.read_blob(pruned)

      # Idempotent.
      assert %{pruned: 0} = Attachments.prune_expired(now: now)
    end

    test "an open ticket's attachments are never pruned by age", ctx do
      %{issue: issue, root: root} = ctx
      {:ok, att} = attach(issue, Fixture.png())
      far = DateTime.add(DateTime.utc_now(), 3650 * 86_400)
      assert %{pruned: 0} = Attachments.prune_expired(now: far)
      assert File.exists?(blob_path(root, att))
    end

    test "a reopened ticket is no longer prunable", ctx do
      %{issue: issue} = ctx
      {:ok, _att} = attach(issue, Fixture.png())
      closed_at = close!(issue)
      reopen!(issue)
      now = DateTime.add(closed_at, 100 * 86_400)
      assert %{pruned: 0} = Attachments.prune_expired(now: now)
    end
  end

  defp blob_path(root, att),
    do: Path.join([root, att.workspace_id, String.slice(att.sha256, 0, 2), "#{att.sha256}.png"])

  # Close a ticket directly in the DB, with a fixed past `closed_at`.
  defp close!(issue, closed_at \\ ~U[2026-01-01 00:00:00.000000Z]) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE issues SET state = 'closed', closed_at = ? WHERE id = ?",
      [DateTime.to_iso8601(closed_at), issue.id]
    )

    closed_at
  end

  # The repo's convention for a hard delete: Ash cannot destroy a ticket (its paper-trail
  # version rows reference it), so tests go around it, versions first.
  defp hard_delete!(issue) do
    Repo.query!("DELETE FROM issues_versions WHERE version_source_id = ?", [issue.id])
    Repo.query!("DELETE FROM issues WHERE id = ?", [issue.id])
  end

  defp reopen!(issue) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE issues SET state = 'active', closed_at = NULL WHERE id = ?",
      [issue.id]
    )
  end
end
