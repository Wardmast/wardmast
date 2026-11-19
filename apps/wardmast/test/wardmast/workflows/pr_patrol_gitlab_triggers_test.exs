defmodule Wardmast.Workflows.PRPatrolGitlabTriggersTest do
  @moduledoc """
  PRPatrol's two main triggers against a GitLab MR (bd-c1htb2 / #1520): a
  reviewer's "request changes" and a failed, non-`allow_failure` job. Both were
  inert on GitLab before the adapter reported `changes_requested` and exported
  `list_required_check_failures/1`. The GitHub-side coverage lives in
  `PRPatrolTest`.
  """

  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}
  alias Wardmast.Worker
  alias Wardmast.Workflows.PRPatrol
  require Ash.Query

  @stub Wardmast.Mergers.Gitlab.HTTP
  @project_path "/api/v4/projects/owner%2Frepo"
  @mr_path @project_path <> "/merge_requests/42"
  @sha "cafe123"

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "prpatrol-gl-#{System.unique_integer([:positive])}",
        prefix: "pg",
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.com",
              "project_id" => "owner/repo",
              "credentials_ref" => "test-gitlab-token"
            }
          }
        }
      })

    tmp = Path.join(System.tmp_dir!(), "prpatrol-gl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo_path = seed_repo!(tmp, "repo")

    put_app_env(:wardmast, :worktree_root, Path.join(tmp, "wt"))
    put_app_env(:wardmast, :repo_paths, %{"owner/repo" => repo_path})

    on_exit(fn ->
      Issue
      |> Ash.Query.filter(not is_nil(source_pr))
      |> Ash.read!()
      |> Enum.each(fn issue ->
        case Worker.whereis(issue.id) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
        end
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, ws: ws}
  end

  defp seed_repo!(tmp, sub) do
    repo = Path.join(tmp, sub)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    remote = Path.join(tmp, sub <> "-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])
    repo
  end

  defp start_patrol(ws) do
    name = String.to_atom("PRPatrolGl_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {PRPatrol,
         repo: "owner/repo",
         workspace_id: ws.id,
         interval_ms: 60_000,
         name: name,
         dispatch_opts: [claude_command: ["sleep", "2"]]}
      )

    Req.Test.allow(@stub, self(), pid)
    name
  end

  defp tasks_for_repo do
    Issue |> Ash.Query.filter(not is_nil(source_pr)) |> Ash.read!()
  end

  # Serves the GitLab calls a patrol tick makes for MR !42 (per-PR signal path —
  # GitLab has no batched signals).
  defp gitlab_stub(opts) do
    reviewers = Keyword.get(opts, :reviewers, [])
    jobs = Keyword.get(opts, :jobs, [])
    pipeline_status = Keyword.get(opts, :pipeline_status, "failed")

    Req.Test.stub(@stub, fn conn ->
      path = conn.request_path
      json = fn body -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(body) end

      cond do
        path == @project_path <> "/merge_requests" ->
          json.([
            %{
              "iid" => 42,
              "title" => "gitlab mr",
              "web_url" => "https://gitlab.com/g/p/-/merge_requests/42",
              "author" => %{"username" => "fleet-bot"}
            }
          ])

        path == @mr_path ->
          json.(%{
            "iid" => 42,
            "state" => "opened",
            "sha" => @sha,
            "web_url" => "https://gitlab.com/g/p/-/merge_requests/42",
            "author" => %{"username" => "fleet-bot"},
            "reviewers" => [%{"id" => 7, "username" => "alice"}]
          })

        path == @mr_path <> "/reviewers" ->
          json.(reviewers)

        path == @mr_path <> "/discussions" ->
          json.([])

        path == @mr_path <> "/pipelines" ->
          json.([%{"id" => 900, "sha" => @sha, "status" => pipeline_status}])

        path == @project_path <> "/pipelines/900/jobs" ->
          json.(jobs)

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "404 Not Found"})
      end
    end)
  end

  defp job(name, status, allow_failure) do
    %{
      "id" => :erlang.phash2(name),
      "name" => name,
      "stage" => "test",
      "status" => status,
      "allow_failure" => allow_failure,
      "failure_reason" => "script_failure",
      "web_url" => "https://gitlab.com/g/p/-/jobs/#{name}"
    }
  end

  test "a reviewer's requested_changes files one follow-up", %{ws: ws} do
    gitlab_stub(
      pipeline_status: "success",
      reviewers: [
        %{
          "user" => %{"id" => 7, "username" => "alice"},
          "state" => "requested_changes",
          "created_at" => "2026-11-01T10:00:00.000Z"
        }
      ]
    )

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    [task] = tasks_for_repo()
    assert task.source_pr == "42"
    assert task.description =~ "CHANGES_REQUESTED"

    # Dedup: the same request_changes is not re-filed on the next tick.
    :ok = PRPatrol.tick(name)
    assert length(tasks_for_repo()) == 1
  end

  test "a failed non-allow_failure job files a required-check follow-up", %{ws: ws} do
    gitlab_stub(jobs: [job("rspec", "failed", false), job("flaky-e2e", "failed", true)])

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    [task] = tasks_for_repo()
    assert task.source_pr == "42"
    assert task.description =~ "required check(s) failing: rspec"
    refute task.description =~ "flaky-e2e"
  end

  test "only allow_failure jobs failed → nothing filed", %{ws: ws} do
    gitlab_stub(jobs: [job("flaky-e2e", "failed", true), job("rspec", "success", false)])

    name = start_patrol(ws)
    :ok = PRPatrol.tick(name)

    assert tasks_for_repo() == []
  end
end
