defmodule Wardmast.Mergers.GitlabReviewSignalsTest do
  @moduledoc """
  GitLab `changes_requested` / `latest_review_id` (reviewers API + opt-in
  discussion fallback) and `list_required_check_failures/1` (head pipeline's
  failed jobs) — bd-c1htb2 / #1520.
  """
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.Gitlab
  alias Wardmast.Mergers.Gitlab.Config

  @project 12_345
  @iid 42
  @ref "!42"
  @sha "deadbeef"
  @env_var "GLRS_GITLAB_TEST_TOKEN"
  @mr_path "/api/v4/projects/#{@project}/merge_requests/#{@iid}"
  @pipelines_path @mr_path <> "/pipelines"
  @reviewers_path @mr_path <> "/reviewers"
  @jobs_path "/api/v4/projects/#{@project}/pipelines/900/jobs"

  setup do
    System.put_env(@env_var, "test-gitlab-token")
    put_config(%{})
    Wardmast.Mergers.Gitlab.Budget.reset()

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp put_config(extra) do
    Config.put_active(
      Map.merge(
        %{
          "host" => "gitlab.com",
          "project_id" => @project,
          "credentials_ref" => "env:#{@env_var}"
        },
        extra
      )
    )
  end

  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  # Routes the GitLab calls the review/check signals make off a map of
  # request_path => response body; an unlisted path is a test failure.
  defp stub_routes(routes) do
    Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
      case Map.fetch(routes, conn.request_path) do
        {:ok, body} ->
          json(conn, body)

        :error ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "404 Not Found"})
      end
    end)
  end

  defp mr_body(extra \\ %{}) do
    Map.merge(
      %{
        "iid" => @iid,
        "state" => "opened",
        "sha" => @sha,
        "web_url" => "https://gitlab.com/g/p/-/merge_requests/42",
        "author" => %{"username" => "fleet-bot"},
        "reviewers" => [%{"id" => 7, "username" => "alice"}]
      },
      extra
    )
  end

  defp reviewer(id, username, state, created_at \\ "2026-11-01T10:00:00.000Z") do
    %{
      "user" => %{"id" => id, "username" => username},
      "state" => state,
      "created_at" => created_at
    }
  end

  defp discussion(id, note_id, author, opts \\ []) do
    %{
      "id" => id,
      "notes" => [
        %{
          "id" => note_id,
          "author" => %{"username" => author},
          "body" => Keyword.get(opts, :body, "please fix"),
          "resolvable" => Keyword.get(opts, :resolvable, true),
          "resolved" => Keyword.get(opts, :resolved, false),
          "position" => %{"new_path" => "lib/a.ex", "new_line" => 3}
        }
      ]
    }
  end

  defp base_routes(extra) do
    Map.merge(
      %{
        @mr_path => mr_body(),
        "#{@mr_path}/pipelines" => [],
        "#{@mr_path}/reviewers" => [],
        "#{@mr_path}/discussions" => []
      },
      extra
    )
  end

  describe "get/1 reviewers API" do
    test "a requested_changes reviewer reports changes_requested + latest_review_id" do
      stub_routes(
        base_routes(%{
          "#{@mr_path}/reviewers" => [
            reviewer(8, "bob", "approved"),
            reviewer(7, "alice", "requested_changes")
          ]
        })
      )

      assert {:ok, %{changes_requested: true, latest_review_id: id}} = Gitlab.get(@ref)
      assert is_binary(id)
      assert id =~ "7"
    end

    test "no requested_changes reviewer → changes_requested false" do
      stub_routes(base_routes(%{"#{@mr_path}/reviewers" => [reviewer(7, "alice", "reviewed")]}))

      assert {:ok, %{changes_requested: false, latest_review_id: nil}} = Gitlab.get(@ref)
    end

    test "the id is stable across a new head commit (so a revise push does not re-trigger)" do
      reviewers = [reviewer(7, "alice", "requested_changes")]
      stub_routes(base_routes(%{"#{@mr_path}/reviewers" => reviewers}))
      {:ok, %{latest_review_id: first}} = Gitlab.get(@ref)

      stub_routes(
        base_routes(%{
          @mr_path => mr_body(%{"sha" => "newsha"}),
          "#{@mr_path}/reviewers" => reviewers
        })
      )

      {:ok, %{latest_review_id: second}} = Gitlab.get(@ref)
      assert first == second
    end

    test "an MR with no reviewers makes no reviewers request" do
      Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
        case conn.request_path do
          @mr_path -> json(conn, mr_body(%{"reviewers" => []}))
          @pipelines_path -> json(conn, [])
        end
      end)

      assert {:ok, %{changes_requested: false}} = Gitlab.get(@ref)
    end

    test "a reviewers-endpoint failure degrades to changes_requested false" do
      Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
        case conn.request_path do
          @mr_path -> json(conn, mr_body())
          @pipelines_path -> json(conn, [])
          @reviewers_path -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, %{changes_requested: false, latest_review_id: nil}} = Gitlab.get(@ref)
    end
  end

  describe "list_review_feedback/1 reviewers API" do
    test "reports changes_requested, latest_review_id and a CHANGES_REQUESTED review item" do
      stub_routes(
        base_routes(%{
          "#{@mr_path}/reviewers" => [reviewer(7, "alice", "requested_changes")]
        })
      )

      assert {:ok, %{changes_requested: true, latest_review_id: id, feedback: feedback}} =
               Gitlab.list_review_feedback(@ref)

      assert is_binary(id)

      assert Enum.any?(
               feedback,
               &(&1.kind == :review and &1.state == "CHANGES_REQUESTED" and &1.author == "alice")
             )
    end

    test "no reviewer state → not requested, empty feedback" do
      stub_routes(base_routes(%{}))

      assert {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}} =
               Gitlab.list_review_feedback(@ref)
    end
  end

  describe "discussion fallback flag (changes_requested_from_discussions)" do
    defp discussions do
      [
        # authored by a reviewer, unresolved → counts
        discussion("d1", 101, "alice"),
        # authored by the MR author → ignored
        discussion("d2", 150, "fleet-bot"),
        # resolved → ignored
        discussion("d3", 90, "alice", resolved: true)
      ]
    end

    test "off by default: unresolved non-author discussions do not request changes" do
      stub_routes(base_routes(%{"#{@mr_path}/discussions" => discussions()}))

      assert {:ok, %{changes_requested: false, latest_review_id: nil}} = Gitlab.get(@ref)

      assert {:ok, %{changes_requested: false, latest_review_id: nil}} =
               Gitlab.list_review_feedback(@ref)
    end

    test "on: an unresolved non-author discussion requests changes" do
      put_config(%{"changes_requested_from_discussions" => true})
      stub_routes(base_routes(%{"#{@mr_path}/discussions" => discussions()}))

      assert {:ok, %{changes_requested: true, latest_review_id: id}} = Gitlab.get(@ref)
      assert is_binary(id) and id =~ "101"

      assert {:ok, %{changes_requested: true, latest_review_id: ^id, feedback: feedback}} =
               Gitlab.list_review_feedback(@ref)

      assert [%{kind: :comment, author: "alice", path: "lib/a.ex", line: 3}] = feedback
    end

    test "on: only author/resolved/non-resolvable discussions → not requested" do
      put_config(%{"changes_requested_from_discussions" => true})

      stub_routes(
        base_routes(%{
          "#{@mr_path}/discussions" => [
            discussion("d2", 150, "fleet-bot"),
            discussion("d3", 90, "alice", resolved: true),
            discussion("d4", 91, "alice", resolvable: false)
          ]
        })
      )

      assert {:ok, %{changes_requested: false, latest_review_id: nil}} = Gitlab.get(@ref)
    end

    test "on: a new unresolved discussion changes the id" do
      put_config(%{"changes_requested_from_discussions" => true})
      stub_routes(base_routes(%{"#{@mr_path}/discussions" => [discussion("d1", 101, "alice")]}))
      {:ok, %{latest_review_id: first}} = Gitlab.get(@ref)

      stub_routes(
        base_routes(%{
          "#{@mr_path}/discussions" => [
            discussion("d1", 101, "alice"),
            discussion("d5", 200, "bob")
          ]
        })
      )

      {:ok, %{latest_review_id: second}} = Gitlab.get(@ref)
      refute first == second
    end

    test "the reviewer state wins over the fallback when both apply" do
      put_config(%{"changes_requested_from_discussions" => true})

      stub_routes(
        base_routes(%{
          "#{@mr_path}/reviewers" => [reviewer(7, "alice", "requested_changes")],
          "#{@mr_path}/discussions" => discussions()
        })
      )

      assert {:ok, %{changes_requested: true, latest_review_id: id}} = Gitlab.get(@ref)
      refute id =~ "101"
    end
  end

  describe "list_required_check_failures/1" do
    defp job(name, status, opts \\ []) do
      %{
        "id" => Keyword.get(opts, :id, :erlang.phash2(name)),
        "name" => name,
        "stage" => "test",
        "status" => status,
        "allow_failure" => Keyword.get(opts, :allow_failure, false),
        "failure_reason" => Keyword.get(opts, :failure_reason, "script_failure"),
        "web_url" => "https://gitlab.com/g/p/-/jobs/#{name}"
      }
    end

    defp check_routes(jobs, pipelines \\ nil) do
      pipelines =
        pipelines ||
          [%{"id" => 900, "sha" => @sha, "status" => "failed", "web_url" => "https://x/p/900"}]

      stub_routes(%{
        @mr_path => mr_body(),
        "#{@mr_path}/pipelines" => pipelines,
        "/api/v4/projects/#{@project}/pipelines/900/jobs" => jobs
      })
    end

    test "returns failed, non-allow_failure jobs of the head pipeline" do
      check_routes([
        job("rspec", "failed"),
        job("lint", "success"),
        job("flaky-e2e", "failed", allow_failure: true)
      ])

      assert {:ok, [%{name: "rspec", summary: summary, url: url}]} =
               Gitlab.list_required_check_failures(@ref)

      assert is_binary(summary)
      assert url == "https://gitlab.com/g/p/-/jobs/rspec"
    end

    test "excludes jobs the workspace marked external" do
      put_config(%{"external_jobs" => ["deploy-preview"]})
      check_routes([job("rspec", "failed"), job("deploy-preview", "failed")])

      assert {:ok, [%{name: "rspec"}]} = Gitlab.list_required_check_failures(@ref)
    end

    test "no failed jobs → []" do
      check_routes([job("rspec", "success"), job("e2e", "running")])
      assert {:ok, []} = Gitlab.list_required_check_failures(@ref)
    end

    test "only the pipeline on the current head sha is consulted" do
      Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fn conn ->
        case conn.request_path do
          @mr_path ->
            json(conn, mr_body())

          @pipelines_path ->
            json(conn, [
              %{"id" => 800, "sha" => "oldsha", "status" => "failed"},
              %{"id" => 900, "sha" => @sha, "status" => "success"}
            ])

          @jobs_path ->
            json(conn, [job("rspec", "success")])
        end
      end)

      assert {:ok, []} = Gitlab.list_required_check_failures(@ref)
    end

    test "no pipeline on the MR → []" do
      stub_routes(%{@mr_path => mr_body(), "#{@mr_path}/pipelines" => []})
      assert {:ok, []} = Gitlab.list_required_check_failures(@ref)
    end

    test "is exported (PRPatrol checks function_exported?/3)" do
      assert function_exported?(Gitlab, :list_required_check_failures, 1)
    end
  end
end
