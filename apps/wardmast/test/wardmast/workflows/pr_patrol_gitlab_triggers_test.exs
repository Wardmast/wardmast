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

  # The MR head the stub serves; tests flip it to simulate a push.
  defp current_sha, do: Application.get_env(:wardmast, :prpatrol_gl_test_sha, @sha)
  defp push!(sha), do: Application.put_env(:wardmast, :prpatrol_gl_test_sha, sha)

  setup do
    on_exit(fn -> Application.delete_env(:wardmast, :prpatrol_gl_test_sha) end)

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
          },
          # bd-cwigjh: an unset `author_logins` patrols only Wardmast-opened MRs;
          # these tests exercise the triggers against an arbitrary author.
          "pr_patrol" => %{"author_logins" => "*"}
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
              "author" => %{"username" => "fleet-bot"},
              "sha" => current_sha()
            }
          ])

        path == @mr_path ->
          json.(%{
            "iid" => 42,
            "state" => "opened",
            "sha" => current_sha(),
            "web_url" => "https://gitlab.com/g/p/-/merge_requests/42",
            "author" => %{"username" => "fleet-bot"},
            "reviewers" => [%{"id" => 7, "username" => "alice"}]
          })

        path == @mr_path <> "/reviewers" ->
          json.(reviewers)

        path == @mr_path <> "/discussions" ->
          json.([])

        path == @mr_path <> "/pipelines" ->
          json.([%{"id" => 900, "sha" => current_sha(), "status" => pipeline_status}])

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

  describe "check-failure dedup (bd-7wwz1f)" do
    defp close_all!(issues) do
      issues
      |> Enum.reject(&(&1.state == :closed))
      |> Enum.each(fn i ->
        {:ok, _} = Ash.update(i, %{close_reason: :completed}, action: :close)
      end)
    end

    defp escalations(ws) do
      "coordinator"
      |> Wardmast.Messages.Message.inbox(workspace_id: ws.id)
      |> Enum.filter(&(&1.escalation_kind == :pr_patrol_check_follow_up_cap))
    end

    test "a closed follow-up does not re-file for the same head + failing set", %{ws: ws} do
      gitlab_stub(jobs: [job("audit:hex", "failed", false)])
      name = start_patrol(ws)

      :ok = PRPatrol.tick(name)
      [task] = tasks_for_repo()
      close_all!([task])

      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)
      assert length(tasks_for_repo()) == 1
    end

    test "a new head SHA re-arms the trigger", %{ws: ws} do
      gitlab_stub(jobs: [job("audit:hex", "failed", false)])
      name = start_patrol(ws)

      :ok = PRPatrol.tick(name)
      close_all!(tasks_for_repo())
      push!("beef456")
      :ok = PRPatrol.tick(name)

      assert length(tasks_for_repo()) == 2
    end

    test "a different failing set re-arms the trigger", %{ws: ws} do
      gitlab_stub(jobs: [job("audit:hex", "failed", false)])
      name = start_patrol(ws)

      :ok = PRPatrol.tick(name)
      close_all!(tasks_for_repo())
      gitlab_stub(jobs: [job("audit:hex", "failed", false), job("rspec", "failed", false)])
      :ok = PRPatrol.tick(name)

      assert length(tasks_for_repo()) == 2
    end

    test "after N follow-ups on one head, patrol escalates once instead of filing", %{ws: ws} do
      gitlab_stub(jobs: [job("a", "failed", false)])
      name = start_patrol(ws)

      :ok = PRPatrol.tick(name)
      close_all!(tasks_for_repo())
      gitlab_stub(jobs: [job("a", "failed", false), job("b", "failed", false)])
      :ok = PRPatrol.tick(name)
      close_all!(tasks_for_repo())
      assert length(tasks_for_repo()) == 2

      gitlab_stub(jobs: Enum.map(~w(a b c), &job(&1, "failed", false)))
      :ok = PRPatrol.tick(name)
      :ok = PRPatrol.tick(name)

      assert length(tasks_for_repo()) == 2
      assert [_one] = escalations(ws)

      # A push re-arms filing.
      push!("beef456")
      :ok = PRPatrol.tick(name)
      assert length(tasks_for_repo()) == 3
    end
  end

  # bd-cwigjh / #1550: with `list_required_check_failures/1` live (bd-c1htb2) an
  # unscoped patrol acts on EVERY MR in the project, including a colleague's.
  describe "author scope (pr_patrol.author_logins)" do
    defp set_patrol_config(ws, patch) do
      {:ok, ws} = Ash.update(ws, %{patch: %{"pr_patrol" => patch}}, action: :patch_config)
      ws
    end

    defp failing_ci_stub, do: gitlab_stub(jobs: [job("rspec", "failed", false)])

    test "unset author_logins → a colleague's MR with a failing check is left alone",
         %{ws: ws} do
      ws = set_patrol_config(ws, %{"author_logins" => nil})
      failing_ci_stub()

      name = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert tasks_for_repo() == []
    end

    test "unset author_logins → an MR authored by the configured fleet login is patrolled",
         %{ws: ws} do
      ws = set_patrol_config(ws, %{"author_logins" => nil, "our_login" => "fleet-bot"})
      failing_ci_stub()

      name = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert [task] = tasks_for_repo()
      assert task.source_pr == "42"
    end

    test "unset author_logins → an MR linked to a Wardmast ticket (pr_ref) is patrolled",
         %{ws: ws} do
      ws = set_patrol_config(ws, %{"author_logins" => nil})

      {:ok, task} =
        Ash.create(Issue, %{
          title: "authored",
          description: "d",
          issue_type: :feature,
          tracker_type: :none,
          workspace_id: ws.id
        })

      {:ok, _} = Ash.update(task, %{pr_ref: "!42"}, action: :update)

      # A review trigger, not CI: a failing check on a ticket-owned MR is the merge
      # flow's to fix (`merge_owns_ci?/4`), so patrol deliberately leaves it be.
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

      assert [followup] = tasks_for_repo()
      assert followup.source_pr == "42"
    end

    test "author_logins \"*\" → every MR is patrolled again", %{ws: ws} do
      ws = set_patrol_config(ws, %{"author_logins" => "*"})
      failing_ci_stub()

      name = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert [_task] = tasks_for_repo()
    end

    test "an explicit login list still scopes to those logins", %{ws: ws} do
      ws = set_patrol_config(ws, %{"author_logins" => ["somebody-else"]})
      failing_ci_stub()

      name = start_patrol(ws)
      :ok = PRPatrol.tick(name)

      assert tasks_for_repo() == []
    end
  end
end
