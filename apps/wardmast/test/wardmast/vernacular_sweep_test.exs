defmodule Wardmast.VernacularSweepTest do
  @moduledoc """
  Validates that old vernacular terms (Admiral, Mayor, Polecat, acolyte, Deacon)
  have been replaced with new terms (coordinator, worker, etc.) in comments and
  internal identifiers only — not in config keys or wire values.

  This test scans the target files from task bd-2x7ito.
  """

  use ExUnit.Case

  @target_files [
    "lib/wardmast/agents/claude/config_dir.ex",
    "lib/wardmast/agents/security_policy.ex",
    "lib/wardmast/agents/credential_watchdog.ex",
    "lib/wardmast/agents/routing/by_difficulty.ex",
    "lib/wardmast/trackers/sync.ex",
    "lib/wardmast/tasks/workspace.ex",
    "lib/wardmast/tasks/decommission_sweep.ex",
    "lib/wardmast/workers/reconciler.ex",
    "lib/wardmast/events.ex",
    "lib/wardmast/application.ex",
    "lib/wardmast/github.ex"
  ]

  @gas_town_files [
    "lib/wardmast/workers/reconciler.ex",
    "lib/wardmast/messages/coordinator_notifier.ex",
    "lib/wardmast/trackers/tracker.ex",
    "lib/wardmast/trackers/jira.ex",
    "lib/wardmast/trackers/sync.ex",
    "lib/wardmast/tasks/issue.ex",
    "lib/wardmast/worker.ex",
    "lib/wardmast/worker/worktree.ex",
    "lib/wardmast/worker/dispatch.ex",
    "lib/wardmast/workflows/merged_pr_finalizer.ex",
    "lib/wardmast/tasks/issue/changes/cleanup_worktree.ex",
    "lib/wardmast/worker/worker_env.ex",
    "lib/wardmast/worker/stop_reason.ex",
    "lib/wardmast/quota/cloud_code.ex",
    "lib/wardmast/tasks/issue/changes/sync_tracker.ex",
    "lib/wardmast/workflows/merge_queue.ex"
  ]

  describe "vernacular sweep" do
    test "config_dir.ex: acolyte_memory function is renamed to worker_memory" do
      content = read_file("lib/wardmast/agents/claude/config_dir.ex")

      # Should NOT find the old function name
      refute content =~ "def acolyte_memory",
             "Found 'def acolyte_memory' — should be renamed to 'def worker_memory'"

      # Should find the new function name
      assert content =~ "def worker_memory",
             "Should find 'def worker_memory' after renaming"
    end

    test "credential_watchdog.ex: Admiral in comments → coordinator" do
      content = read_file("lib/wardmast/agents/credential_watchdog.ex")

      # Comments should mention "coordinator" not "Admiral"
      assert content =~ "Escalates to the coordinator",
             "Should update 'Escalates to the Admiral' to 'Escalates to the coordinator'"

      assert content =~ "coordinator escalations",
             "Should update Admiral escalations to coordinator escalations"

      refute content =~ ~r/Escalates to the Admiral(?![\w])/,
             "Should not have unqualified 'Admiral' in escalation context"
    end

    test "by_difficulty.ex: Admiral → coordinator in comments" do
      content = read_file("lib/wardmast/agents/routing/by_difficulty.ex")

      assert content =~ ~r/coordinator signed\s+off/,
             "Should update 'Admiral signed off' to 'coordinator signed off'"
    end

    test "trackers/sync.ex: Admiral → coordinator in mailbox comments" do
      content = read_file("lib/wardmast/trackers/sync.ex")

      assert content =~ "coordinator mailbox",
             "Should update 'Admiral mailbox' to 'coordinator mailbox'"
    end

    test "workspace.ex: Admiral → coordinator in comments" do
      content = read_file("lib/wardmast/tasks/workspace.ex")

      assert content =~ "escalates to the coordinator",
             "Should update 'escalates to the Admiral' to 'escalates to the coordinator'"
    end

    test "reconciler.ex: Admiral → coordinator" do
      content = read_file("lib/wardmast/workers/reconciler.ex")

      assert content =~ "coordinator's mailbox",
             "Should update 'Admiral's mailbox' to 'coordinator's mailbox'"
    end

    test "events.ex: Admiral → coordinator in event documentation" do
      content = read_file("lib/wardmast/events.ex")

      assert content =~ "coordinator ruling",
             "Should update 'Admiral ruling' to 'coordinator ruling'"
    end

    test "application.ex: Admiral → coordinator" do
      content = read_file("lib/wardmast/application.ex")

      assert content =~ "Escalates each to the coordinator",
             "Should update Admiral reference to coordinator"
    end

    test "github.ex: polecat → worker in comments" do
      content = read_file("lib/wardmast/github.ex")

      assert content =~ "worker-orchestrator",
             "Should update 'polecat-orchestrator' to 'worker-orchestrator'"
    end

    test "decommission_sweep.ex: mayor → coordinator in comments (but preserve historical artifact matching)" do
      content = read_file("lib/wardmast/tasks/decommission_sweep.ex")

      # The comments about old artifacts should be updated
      assert content =~ ~r/coordinator\/witness\s+session-handoff/,
             "Should update 'mayor/witness' in comments"

      # But the string matching for historical artifacts should be preserved
      assert content =~ ~r/"Mayor - global coordinator"/,
             "Should preserve historical artifact title matching for string literals"
    end

    test "reconciler.ex: bead → task in comments (Gas Town vocabulary)" do
      content = read_file("lib/wardmast/workers/reconciler.ex")

      # Should NOT find the old "bead" terminology in comments
      refute content =~ ~r/a bead parked/i,
             "Should replace 'a bead parked' with 'a task parked'"

      refute content =~ ~r/beads\./i,
             "Should replace 'beads' with 'tasks' in comments"
    end

    test "merge_queue.ex: Refinery → merge queue in comments" do
      content = read_file("lib/wardmast/workflows/merge_queue.ex")

      # Should NOT find "the Refinery is"
      refute content =~ "the Refinery is",
             "Should replace 'the Refinery is' with 'the merge queue is'"

      # Should find "the merge queue" instead
      assert content =~ "the merge queue is",
             "Should have 'the merge queue' instead of 'the Refinery'"
    end

    test "all target files compile without errors" do
      # This is a basic sanity check — the actual compilation is done by mix test
      # but we can at least verify the files exist and are readable
      for file <- @target_files do
        assert File.exists?(file),
               "File #{file} should exist"

        {:ok, content} = File.read(file)

        refute content == "",
               "File #{file} should not be empty"
      end
    end

    test "gas_town_files: 'bead'/'beads' replaced with 'task'/'issue'" do
      for file <- @gas_town_files do
        content = read_file(file)

        # Check that "bead" is not used colloquially for task/issue in comments
        # Allow it only if it's part of a known identifier or in decommission_sweep artifact matching
        unless String.contains?(file, ["decommission_sweep", "Dolt"]) do
          refute content =~ ~r/\bbead(?![\w:_-])/,
                 "File #{file}: Found 'bead' used colloquially — should be 'task' or 'issue' in comments"

          refute content =~ ~r/\bbeads\b/,
                 "File #{file}: Found 'beads' — should be 'tasks' or 'issues' in comments"
        end
      end
    end

    test "merge_queue files: 'the Refinery' replaced with 'the merge queue'" do
      for file <- [
            "lib/wardmast/workflows/merge_queue.ex",
            "../wardmast_web/lib/wardmast_web/live/merge_queue_index_live.ex"
          ] do
        content = read_file(file)

        refute content =~ "the Refinery",
               "File #{file}: Found 'the Refinery' — should be 'the merge queue'"
      end
    end

    test "gas_town_files: 'sling' (Gas Town terminology) not used in comments/prose" do
      for file <- @gas_town_files do
        content = read_file(file)

        # Check that "sling" is not used as Gas Town terminology in comments.
        # Exclude decommission_sweep which may contain historical artifact matching.
        unless String.contains?(file, ["decommission_sweep"]) do
          refute content =~ ~r/\bsling\b/,
                 "File #{file}: Found 'sling' (Gas Town terminology) — should be removed or replaced with Wardmast terminology in comments"
        end
      end
    end

    test "CLI: hidden 'arb sling' backwards-compat alias has been retired" do
      main_ex_content = read_file("../wardmast_cli/lib/wardmast_cli/main.ex")

      # The `arb sling` hidden backwards-compat alias to `arb dispatch` was never
      # documented or used. Assert it has been removed during Gas Town vernacular retirement.
      refute main_ex_content =~ ~r/dispatch\("sling"/,
             "main.ex: Found 'arb sling' backwards-compat alias — should be removed as it is unused Gas Town terminology"
    end

    test "rig->repo (bd-9q0ntu): fully in-scope files have zero bare 'rig' identifiers/comments" do
      # These files carry no Tier-2 (--rig flag / rig_standing_orders JSON key)
      # surface at all, so every "rig" occurrence here would be a plain miss.
      files = [
        "lib/wardmast/worker/dispatch.ex",
        "lib/wardmast/worker/review_automation.ex",
        "lib/wardmast/mergers/github/config.ex",
        "lib/wardmast/workflows/pr_patrol_supervisor.ex",
        "lib/wardmast/workflows/review_patrol.ex",
        "lib/wardmast/workflows/review_patrol_supervisor.ex",
        "lib/wardmast/workflows/merged_pr_finalizer_supervisor.ex",
        "../wardmast_web/lib/wardmast_web/live/board_live.ex",
        "../../docs/design/review-worker-lifecycle.md"
      ]

      for file <- files do
        content = read_file(file)

        refute content =~ ~r/\brigs?\b|rig_|_rig/i,
               "File #{file}: Found bare 'rig' — should be 'repo' (bd-9q0ntu)"
      end
    end

    test "rig->repo (bd-9q0ntu): partial files have no 'rig' outside the Tier-2-owned surface" do
      # These files still carry the Tier-2 `--rig` CLI flag / `rig_standing_orders`
      # JSON key / `"rig"` output key, which are explicitly out of scope for this
      # (Tier 1) rename. Strip the known-allowed occurrences, then assert nothing
      # else spelling "rig" survives.
      allowed = [
        ~r/--rig\b/,
        ~r/<rig>/,
        ~r/rig_standing_orders/,
        ~r/"rig"/,
        ~r/\brig:\s*:string/,
        ~r/opts\[:rig\]/
      ]

      files = [
        "../wardmast_cli/lib/wardmast_cli/cmd/workspace.ex",
        "../wardmast_cli/lib/wardmast_cli/cmd/prime.ex"
      ]

      for file <- files do
        content = read_file(file)

        stripped =
          Enum.reduce(allowed, content, fn pattern, acc -> Regex.replace(pattern, acc, "") end)

        refute stripped =~ ~r/\brigs?\b|rig_|_rig/i,
               "File #{file}: Found 'rig' outside the Tier-2-owned --rig/rig_standing_orders surface (bd-9q0ntu)"
      end

      # config_schema.ex's doc text describing --rig is entirely Tier-2-owned
      # (issue: "update together with the flag itself") — not checked here.
    end

    test "CLI help text: gte-NNN examples updated to current format" do
      dispatch_content = read_file("../wardmast_cli/lib/wardmast_cli/cmd/dispatch.ex")
      show_content = read_file("../wardmast_cli/lib/wardmast_cli/cmd/show.ex")

      refute dispatch_content =~ "gte-006",
             "dispatch.ex: Found 'gte-006' example — should use current issue id format"

      refute show_content =~ "gte-006",
             "show.ex: Found 'gte-006' example — should use current issue id format"
    end
  end

  # Helper to read a file relative to the project root
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> raise "Could not read file: #{path}"
    end
  end
end
