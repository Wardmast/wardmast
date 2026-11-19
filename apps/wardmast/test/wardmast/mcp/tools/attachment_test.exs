defmodule Wardmast.MCP.Tools.AttachmentTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.AttachmentFixture, as: Fixture
  alias Wardmast.Attachments
  alias Wardmast.MCP.Catalog
  alias Wardmast.MCP.Scope
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

    {:ok, ws} = Ash.create(Workspace, %{name: "mcp-att-a", prefix: "maa"})
    {:ok, other_ws} = Ash.create(Workspace, %{name: "mcp-att-b", prefix: "mab"})
    mine = make_issue(ws, "mine")
    sibling = make_issue(ws, "sibling")
    foreign = make_issue(other_ws, "foreign")

    worker = %Scope{tier: :worker, workspace_id: ws.id, task_id: mine.id}
    coordinator = %Scope{tier: :coordinator, workspace_id: nil}
    bound = %Scope{tier: :coordinator, workspace_id: ws.id}
    refine = %Scope{tier: :refine, workspace_id: ws.id, issue_id: mine.id, session_id: "s"}

    {:ok,
     ws: ws,
     mine: mine,
     sibling: sibling,
     foreign: foreign,
     worker: worker,
     coordinator: coordinator,
     bound: bound,
     refine: refine}
  end

  defp make_issue(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ac"})
    issue
  end

  defp b64(data), do: Base.encode64(data)

  describe "ticket_attach" do
    test "a worker attaches to its own ticket; the source comes from its tier", ctx do
      assert {:ok, %{attachment: att}} =
               Catalog.call(ctx.worker, "ticket_attach", %{
                 "data" => b64(Fixture.png(100, 50)),
                 "filename" => "after.png",
                 "caption" => "The new button",
                 "role" => "after",
                 "shot_id" => "home"
               })

      assert att.task_id == ctx.mine.id
      assert att.source == "worker"
      assert att.content_type == "image/png"
      assert {att.width, att.height} == {100, 50}
      assert att.role == "after"
      assert att.url == "/attachments/#{att.id}"
      assert [%{id: id}] = Attachments.list(ctx.mine.id)
      assert id == att.id
    end

    test "a worker cannot attach to another ticket, even in its own workspace", ctx do
      assert {:rpc_error, _, _} =
               Catalog.call(ctx.worker, "ticket_attach", %{
                 "id" => ctx.sibling.id,
                 "data" => b64(Fixture.png())
               })

      assert Attachments.list(ctx.sibling.id) == []
    end

    test "a coordinator attaches to any ticket; a bound one reaches only its workspace", ctx do
      assert {:ok, %{attachment: %{source: "coordinator"}}} =
               Catalog.call(ctx.coordinator, "ticket_attach", %{
                 "id" => ctx.sibling.id,
                 "data" => b64(Fixture.jpeg())
               })

      assert {:tool_error, _, "not_found"} =
               Catalog.call(ctx.bound, "ticket_attach", %{
                 "id" => ctx.foreign.id,
                 "data" => b64(Fixture.png())
               })

      assert Attachments.list(ctx.foreign.id) == []
    end

    test "the source is never taken from the arguments", ctx do
      {:ok, tool} = Catalog.fetch("ticket_attach")
      schema = tool.input_schema
      refute Map.has_key?(schema["properties"], "source")

      assert {:tool_error, _, "validation_error"} =
               Catalog.call(ctx.worker, "ticket_attach", %{
                 "data" => b64(Fixture.png()),
                 "source" => "arbiter-capture"
               })
    end

    test "rejects bad base64, non-images and oversize images", ctx do
      assert {:tool_error, "data is not valid base64", "validation_error"} =
               Catalog.call(ctx.worker, "ticket_attach", %{"data" => "!!!not base64"})

      assert {:tool_error, "only png, webp and jpg images can be attached", "validation_error"} =
               Catalog.call(ctx.worker, "ticket_attach", %{"data" => b64("<svg/>")})

      assert {:tool_error, "image exceeds" <> _, "validation_error"} =
               Catalog.call(ctx.worker, "ticket_attach", %{
                 "data" => b64(Fixture.png(4, 3, bytes: 2_097_153))
               })

      assert Attachments.list(ctx.mine.id) == []
    end

    test "a refine session cannot attach", ctx do
      assert {:rpc_error, _, _} =
               Catalog.call(ctx.refine, "ticket_attach", %{"data" => b64(Fixture.png())})
    end
  end

  describe "ticket_attachment_list" do
    setup ctx do
      {:ok, _} =
        Attachments.create(
          ctx.mine,
          %{data: Fixture.png(4, 3, salt: "1"), role: "before", shot_id: "p"},
          source: "worker"
        )

      {:ok, _} =
        Attachments.create(
          ctx.mine,
          %{data: Fixture.png(4, 3, salt: "2"), role: "after", shot_id: "p"},
          source: "worker"
        )

      {:ok, _} = Attachments.create(ctx.sibling, %{data: Fixture.png()}, source: "worker")
      :ok
    end

    test "a worker lists its own ticket's attachments, metadata only", ctx do
      assert {:ok, %{task_id: id, attachments: [first, second]}} =
               Catalog.call(ctx.worker, "ticket_attachment_list", %{})

      assert id == ctx.mine.id
      assert {first.role, second.role} == {"before", "after"}
      refute Map.has_key?(first, :data)
      assert first.url =~ "/attachments/"
    end

    test "a worker cannot list a sibling's attachments", ctx do
      assert {:rpc_error, _, _} =
               Catalog.call(ctx.worker, "ticket_attachment_list", %{"id" => ctx.sibling.id})
    end

    test "a coordinator lists any ticket's; a workspace-bound one gets not-found cross-workspace",
         ctx do
      assert {:ok, %{attachments: [_]}} =
               Catalog.call(ctx.coordinator, "ticket_attachment_list", %{"id" => ctx.sibling.id})

      assert {:tool_error, _, "not_found"} =
               Catalog.call(ctx.bound, "ticket_attachment_list", %{"id" => ctx.foreign.id})

      assert {:tool_error, _, "validation_error"} =
               Catalog.call(ctx.coordinator, "ticket_attachment_list", %{})
    end

    test "a refine session may read", ctx do
      assert {:ok, %{attachments: [_, _]}} =
               Catalog.call(ctx.refine, "ticket_attachment_list", %{})
    end
  end
end
