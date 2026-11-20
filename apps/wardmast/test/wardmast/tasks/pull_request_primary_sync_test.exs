defmodule Wardmast.Tasks.PullRequestPrimarySyncTest do
  @moduledoc """
  bd-2rdfsh: the primary checkout's local target branch stopped advancing
  because only `MergeQueue` synced it after a merge, while the Watchdog merges
  a ReviewGate-approved PR itself (`Watchdog.finish_merged/1` →
  `PullRequest.merged/2`) and the queue then skips the already-closed ticket.
  `PullRequest.merged/2` is the funnel both Watchdog merge paths end in.
  """

  use Wardmast.DataCase, async: false

  import Wardmast.LifecycleFixtures

  alias Wardmast.Tasks.{Issue, PullRequest, Workspace}

  setup do
    tmp = Path.join(System.tmp_dir!(), "prps-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    remote = Path.join(tmp, "remote.git")
    git!(["init", "-q", "--bare", "-b", "main", remote])

    seed = Path.join(tmp, "seed")
    File.mkdir_p!(seed)
    git!(["init", "-q", "-b", "main", seed])
    configure_identity(seed)
    File.write!(Path.join(seed, "README.md"), "hi\n")
    git!(["-C", seed, "add", "README.md"])
    git!(["-C", seed, "commit", "-q", "-m", "initial"])
    git!(["-C", seed, "remote", "add", "origin", remote])
    git!(["-C", seed, "push", "-q", "origin", "main"])

    primary = Path.join(tmp, "primary")
    git!(["clone", "-q", remote, primary])
    configure_identity(primary)

    # What the merge just did upstream: origin/main moves past the primary's
    # local main.
    File.write!(Path.join(seed, "MERGED.md"), "merged\n")
    git!(["-C", seed, "add", "MERGED.md"])
    git!(["-C", seed, "commit", "-q", "-m", "merged change"])
    git!(["-C", seed, "push", "-q", "origin", "main"])

    %{primary: primary, seed: seed}
  end

  defp git!(args) do
    {_, 0} = System.cmd("git", args, stderr_to_stdout: true)
    :ok
  end

  defp configure_identity(path) do
    git!(["-C", path, "config", "user.email", "t@e.com"])
    git!(["-C", path, "config", "user.name", "T"])
    git!(["-C", path, "config", "commit.gpgsign", "false"])
  end

  defp head(path) do
    {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(out)
  end

  defp merging_task(primary, merge_config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pr-sync-#{System.unique_integer([:positive])}",
        prefix: "pz",
        config: %{"merge" => merge_config, "repo_paths" => %{"widget" => primary}}
      })

    {:ok, task} =
      Ash.create(Issue, %{
        title: "merged by the watchdog",
        workspace_id: ws.id,
        issue_type: :feature,
        repo: "widget"
      })

    task = put_state!(task, :active)
    {:ok, _} = Issue.pr_opened(task.id, "#77")
    task
  end

  test "a merge finalized by the Watchdog path fast-forwards a stale primary checkout", %{
    primary: primary,
    seed: seed
  } do
    task = merging_task(primary, %{"auto_sync_primary" => true})
    stale = head(primary)
    refute stale == head(seed)

    assert {:ok, :closed} = PullRequest.merged(task.id, mr_ref: "#77")

    assert head(primary) == head(seed)
    assert File.exists?(Path.join(primary, "MERGED.md"))
  end

  test "leaves the primary checkout alone when auto_sync_primary is off (the default)", %{
    primary: primary
  } do
    task = merging_task(primary, %{})
    before = head(primary)

    assert {:ok, :closed} = PullRequest.merged(task.id, mr_ref: "#77")

    assert head(primary) == before
  end
end
