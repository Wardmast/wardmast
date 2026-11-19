defmodule Wardmast.Workflows.MergeQueueReviseGitlabTest do
  @moduledoc """
  The MergeQueue's CHANGES_REQUESTED → auto-revise path for a GitLab MR
  (bd-c1htb2 / #1520). Before the GitLab adapter reported `changes_requested`
  the path was inert on GitLab; the GitHub side is covered by
  `MergeQueueReviseTest`.
  """

  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Workflows.MergeQueue

  @mr_path "/api/v4/projects/12345/merge_requests/42"

  defmodule Dispatcher do
    @moduledoc false
    @behaviour Wardmast.Workflows.MergeQueue.ReviseDispatcher

    @impl true
    def dispatch(args) do
      case :persistent_term.get({__MODULE__, args.task_id}, nil) do
        nil ->
          {:error, :no_callback_registered}

        pid ->
          send(pid, {:revise_called, args})
          {:ok, %{worker_pid: pid, worktree_path: "/tmp/fake", branch: "x"}}
      end
    end

    def register(task_id, pid), do: :persistent_term.put({__MODULE__, task_id}, pid)
    def unregister(task_id), do: :persistent_term.erase({__MODULE__, task_id})
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "rg#{System.unique_integer([:positive])}",
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.com",
              "project_id" => 12_345,
              "credentials_ref" => "test-gitlab-token"
            }
          }
        }
      })

    {:ok, task} = Ash.create(Issue, %{title: "revise me", description: "d", workspace_id: ws.id})
    {:ok, task} = Ash.update(task, %{pr_ref: "!42"}, action: :update)

    Dispatcher.register(task.id, self())
    on_exit(fn -> Dispatcher.unregister(task.id) end)

    %{ws: ws, task: task}
  end

  defp start_queue(ws) do
    name = :"merge_queue_revise_gl_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: ws.id,
        base: "main",
        auto_tick: false,
        revise_dispatcher: Dispatcher,
        name: name
      )

    Req.Test.allow(Wardmast.Mergers.Gitlab.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Wardmast.Repo, self(), pid)
    name
  end

  # Serves the GitLab calls a tick makes. `reviewers` is the reviewers-API body;
  # `discussions` the discussions body.
  defp gitlab_stub(reviewers, discussions \\ []) do
    test_pid = self()

    Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
      path = conn.request_path
      json = fn body, status -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body) end

      cond do
        conn.method == "GET" and path == @mr_path ->
          json.(
            %{
              "iid" => 42,
              "state" => "opened",
              "sha" => "abc",
              "web_url" => "https://gitlab.com/g/p/-/merge_requests/42",
              "author" => %{"username" => "fleet-bot"},
              "reviewers" => [%{"id" => 7, "username" => "alice"}]
            },
            200
          )

        conn.method == "GET" and path == @mr_path <> "/pipelines" ->
          json.([], 200)

        conn.method == "GET" and path == @mr_path <> "/reviewers" ->
          json.(reviewers, 200)

        conn.method == "GET" and path == @mr_path <> "/discussions" ->
          json.(discussions, 200)

        conn.method == "POST" and path == @mr_path <> "/notes" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:ack_posted, Jason.decode!(body)["body"]})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

        true ->
          json.(%{}, 404)
      end
    end)
  end

  defp requested_changes(created_at \\ "2026-11-01T10:00:00.000Z") do
    [
      %{
        "user" => %{"id" => 7, "username" => "alice"},
        "state" => "requested_changes",
        "created_at" => created_at
      }
    ]
  end

  test "a reviewer's requested_changes dispatches one revise, then debounces", %{
    ws: ws,
    task: task
  } do
    gitlab_stub(requested_changes())
    name = start_queue(ws)
    :ok = MergeQueue.enqueue(name, task.id)

    %{items: [item]} = MergeQueue.state(name)
    assert item.status == :awaiting_approval

    :ok = MergeQueue.tick(name)

    assert_received {:revise_called, args}
    assert args.task_id == task.id
    assert args.pr_ref == "!42"
    assert Enum.any?(args.feedback, &(&1.state == "CHANGES_REQUESTED" and &1.author == "alice"))
    assert_received {:ack_posted, ack}
    assert ack =~ "review feedback"

    %{items: [item]} = MergeQueue.state(name)
    assert item.status == :changes_requested
    assert item.last_handled_review_id =~ "reviewer:7"

    # Same reviewer state on later ticks → no second revise.
    for _ <- 1..3, do: :ok = MergeQueue.tick(name)
    refute_received {:revise_called, _}
  end

  test "no requested_changes reviewer → no revise", %{ws: ws, task: task} do
    gitlab_stub([%{"user" => %{"id" => 7}, "state" => "reviewed", "created_at" => "x"}])
    name = start_queue(ws)
    :ok = MergeQueue.enqueue(name, task.id)

    :ok = MergeQueue.tick(name)

    refute_received {:revise_called, _}
    %{items: [item]} = MergeQueue.state(name)
    refute item.status == :changes_requested
  end

  test "an unresolved non-author discussion alone does not revise unless the flag is on",
       %{ws: ws, task: task} do
    discussions = [
      %{
        "id" => "d1",
        "notes" => [
          %{
            "id" => 101,
            "author" => %{"username" => "alice"},
            "body" => "please fix",
            "resolvable" => true,
            "resolved" => false
          }
        ]
      }
    ]

    gitlab_stub([], discussions)
    name = start_queue(ws)
    :ok = MergeQueue.enqueue(name, task.id)
    :ok = MergeQueue.tick(name)
    refute_received {:revise_called, _}
  end
end
