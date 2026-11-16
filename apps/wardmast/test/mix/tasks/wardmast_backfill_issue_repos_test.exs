defmodule Mix.Tasks.Wardmast.BackfillIssueReposTest do
  # Same reasoning as arbiter_backfill_codex_usage_test.exs: static assertion
  # that this task delegates to Wardmast.Release.backfill/2 (Ash + Repo only)
  # rather than booting the full application (bd-64ye6w).
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.backfill_issue_repos.ex")
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"

    assert @run_body =~ "Wardmast.Release.backfill(:issue_repos",
           "must delegate to the release-callable backfill"
  end

  test "documents the release eval invocation" do
    assert @source =~ "bin/wardmast eval"
    assert @source =~ "Wardmast.Release.backfill(:issue_repos"
  end
end
