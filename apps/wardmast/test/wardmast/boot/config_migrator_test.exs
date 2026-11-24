defmodule Wardmast.Boot.ConfigMigratorTest do
  # Exercises the real `rig_paths` -> `repo_paths` data migration against the
  # sandboxed DB, so `async: false` (workspace reads are global).
  use Wardmast.DataCase, async: false

  import ExUnit.CaptureLog

  alias Wardmast.Boot.ConfigMigrator
  alias Wardmast.Tasks.Workspace

  defp create_ws!(name, config) do
    Ash.create!(Workspace, %{name: name, config: config})
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  describe "child_spec/1" do
    test "is a one-shot temporary worker with this module's id" do
      spec = ConfigMigrator.child_spec([])

      assert spec.id == Wardmast.Boot.ConfigMigrator
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert {Wardmast.Boot.ConfigMigrator, :start_link, [[]]} = spec.start
    end
  end

  describe "migrate_rig_paths/1" do
    test "copies a legacy rig_paths map to repo_paths and drops the old key" do
      ws =
        create_ws!("legacy", %{
          "rig_paths" => %{
            "apex-specs" => %{"path" => "/srv/apex-specs", "target_branch" => "develop"},
            "tonic" => "/srv/tonic"
          }
        })

      assert [result] = ConfigMigrator.migrate_rig_paths()
      assert result.workspace == "legacy"
      assert result.status == :migrated
      # `:repos` is documented as the SORTED repo list (`Enum.sort` in
      # `ConfigMigrator.plan/1`), so the order is alphabetical, not the map's.
      assert result.repos == ["apex-specs", "tonic"]

      config = reload!(ws).config

      assert config["repo_paths"] == %{
               "apex-specs" => %{"path" => "/srv/apex-specs", "target_branch" => "develop"},
               "tonic" => "/srv/tonic"
             }

      refute Map.has_key?(config, "rig_paths")
    end

    test "is a no-op on a workspace that never carried rig_paths" do
      ws = create_ws!("modern", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.migrate_rig_paths() == []
      assert reload!(ws).config == %{"repo_paths" => %{"tonic" => "/srv/tonic"}}
    end

    test "is idempotent — a second run finds nothing left to migrate" do
      create_ws!("legacy", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert [_] = ConfigMigrator.migrate_rig_paths()
      assert ConfigMigrator.migrate_rig_paths() == []
    end

    test "merges into an existing repo_paths, with repo_paths winning on collision" do
      ws =
        create_ws!("both", %{
          "rig_paths" => %{"tonic" => "/old/tonic", "specs" => "/srv/specs"},
          "repo_paths" => %{"tonic" => "/new/tonic"}
        })

      assert [result] = ConfigMigrator.migrate_rig_paths()
      assert result.status == :migrated

      config = reload!(ws).config
      assert config["repo_paths"] == %{"tonic" => "/new/tonic", "specs" => "/srv/specs"}
      refute Map.has_key?(config, "rig_paths")
    end

    test "apply?: false reports what would move without writing" do
      ws = create_ws!("dry", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert [result] = ConfigMigrator.migrate_rig_paths(apply?: false)
      assert result.status == :dry_run
      assert result.repos == ["tonic"]
      assert result.repo_paths == %{"tonic" => "/srv/tonic"}

      config = reload!(ws).config
      assert config["rig_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(config, "repo_paths")
    end

    # bd-3pqzsa review: `repo_paths` is not validated anywhere (ValidateConfig
    # allows unknown keys), and an operator debugging the zero-repos symptom is
    # very likely to type `arb config set repo_paths /srv/foo`, which stores a
    # bare string. Merging that would raise inside a supervision-tree child and
    # the server would not boot at all.
    test "a non-map repo_paths is replaced rather than raising" do
      ws =
        create_ws!("malformed", %{
          "rig_paths" => %{"tonic" => "/srv/tonic"},
          "repo_paths" => "/srv/apex-specs"
        })

      log =
        capture_log(fn ->
          assert [result] = ConfigMigrator.migrate_rig_paths()
          assert result.status == :migrated
          assert result.repos == ["tonic"]
        end)

      assert log =~ "non-map repo_paths"

      config = reload!(ws).config
      assert config["repo_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(config, "rig_paths")
    end

    test "a non-map repo_paths does not stop other workspaces from migrating" do
      bad = create_ws!("bad", %{"rig_paths" => %{"a" => "/srv/a"}, "repo_paths" => 42})
      good = create_ws!("good", %{"rig_paths" => %{"b" => "/srv/b"}})

      capture_log(fn ->
        assert results = ConfigMigrator.migrate_rig_paths()
        assert length(results) == 2
        assert Enum.all?(results, &(&1.status == :migrated))
      end)

      assert reload!(bad).config["repo_paths"] == %{"a" => "/srv/a"}
      assert reload!(good).config["repo_paths"] == %{"b" => "/srv/b"}
    end

    test "a non-map rig_paths is not a migration candidate at all" do
      ws = create_ws!("junk", %{"rig_paths" => "/srv/tonic"})

      assert ConfigMigrator.migrate_rig_paths() == []
      assert reload!(ws).config == %{"rig_paths" => "/srv/tonic"}
    end

    test "logs a warning naming the workspace and the repos it moved" do
      create_ws!("loud", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      log = capture_log(fn -> ConfigMigrator.migrate_rig_paths() end)

      assert log =~ "rig_paths"
      assert log =~ "repo_paths"
      assert log =~ "loud"
    end
  end

  # bd-4j0nfe: a root `sandbox` key is read by nothing (SecurityPolicy reads
  # `agent.security.sandbox`), yet `arb config get sandbox` showed it as live.
  describe "migrate_root_sandbox/1" do
    # `:create` folds a root `sandbox` itself now, so a legacy config is planted
    # with raw SQL, the way a pre-bd-4j0nfe `force` write left it.
    defp plant_ws!(name, config) do
      ws = create_ws!(name, %{})

      Wardmast.Repo.query!("UPDATE workspaces SET config = ?1 WHERE id = ?2", [
        Jason.encode!(config),
        ws.id
      ])

      ws
    end

    defp canonical_sandbox(ws), do: get_in(reload!(ws).config, ["agent", "security", "sandbox"])

    test "root auto vs canonical bwrap: the canonical value wins and the root value is reported dropped" do
      ws =
        plant_ws!("disagree", %{
          "sandbox" => %{"backend" => "auto"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "bwrap"}}}
        })

      log = capture_log(fn -> send(self(), {:r, ConfigMigrator.migrate_root_sandbox()}) end)
      assert_received {:r, [result]}

      assert result.workspace == "disagree"
      assert result.status == :migrated
      assert result.dropped == [{"sandbox.backend", "auto"}]
      assert result.moved == []

      refute Map.has_key?(reload!(ws).config, "sandbox")
      assert canonical_sandbox(ws) == %{"backend" => "bwrap"}

      assert log =~ "disagree"
      assert log =~ "sandbox.backend"
      assert log =~ ~s("auto")
      assert log =~ "agent.security.sandbox.backend"
    end

    test "a root value with no canonical counterpart moves onto the canonical path" do
      ws =
        plant_ws!("root-only", %{
          "sandbox" => %{"backend" => "podman", "egress" => "allowlist"},
          "agent" => %{"security" => %{"sandbox" => %{"review_backend" => "podman"}}}
        })

      capture_log(fn -> send(self(), {:r, ConfigMigrator.migrate_root_sandbox()}) end)
      assert_received {:r, [result]}

      assert Enum.sort(result.moved) == [
               {"sandbox.backend", "agent.security.sandbox.backend"},
               {"sandbox.egress", "agent.security.sandbox.egress"}
             ]

      assert result.dropped == []

      assert canonical_sandbox(ws) == %{
               "backend" => "podman",
               "egress" => "allowlist",
               "review_backend" => "podman"
             }

      refute Map.has_key?(reload!(ws).config, "sandbox")
    end

    test "an equal root value is neither moved nor dropped, only cleared" do
      ws =
        plant_ws!("agree", %{
          "sandbox" => %{"backend" => "auto"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "auto"}}}
        })

      capture_log(fn -> send(self(), {:r, ConfigMigrator.migrate_root_sandbox()}) end)
      assert_received {:r, [%{moved: [], dropped: [], status: :migrated}]}

      assert reload!(ws).config == %{
               "agent" => %{"security" => %{"sandbox" => %{"backend" => "auto"}}}
             }
    end

    test "a non-map root sandbox is cleared and reported dropped" do
      ws = plant_ws!("junk-root", %{"sandbox" => "podman"})

      capture_log(fn -> send(self(), {:r, ConfigMigrator.migrate_root_sandbox()}) end)
      assert_received {:r, [%{dropped: [{"sandbox", "podman"}], status: :migrated}]}
      refute Map.has_key?(reload!(ws).config, "sandbox")
    end

    test "is a no-op without a root sandbox, and idempotent" do
      create_ws!("clean", %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "bwrap"}}}})
      plant_ws!("once", %{"sandbox" => %{"backend" => "podman"}})

      capture_log(fn -> assert [%{workspace: "once"}] = ConfigMigrator.migrate_root_sandbox() end)
      assert ConfigMigrator.migrate_root_sandbox() == []
    end

    test "apply?: false reports without writing" do
      ws = plant_ws!("dry", %{"sandbox" => %{"backend" => "podman"}})

      capture_log(fn ->
        assert [%{status: :dry_run}] = ConfigMigrator.migrate_root_sandbox(apply?: false)
      end)

      assert reload!(ws).config == %{"sandbox" => %{"backend" => "podman"}}
    end
  end

  describe "start_link/1" do
    @tag capture_log: true
    test "folds a root sandbox on the primary instance" do
      ws = plant_ws!("primary-sandbox", %{"sandbox" => %{"backend" => "podman"}})

      assert ConfigMigrator.start_link(primary?: true) == :ignore
      refute Map.has_key?(reload!(ws).config, "sandbox")
      assert get_in(reload!(ws).config, ["agent", "security", "sandbox", "backend"]) == "podman"
    end

    test "migrates and returns :ignore on the primary instance" do
      ws = create_ws!("primary", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.start_link(primary?: true) == :ignore
      assert reload!(ws).config["repo_paths"] == %{"tonic" => "/srv/tonic"}
    end

    # A raise here would fail Supervisor.start_link/2 and the server would not
    # boot at all — worse than the zero-repos bug this module exists to fix.
    test "a malformed workspace config never aborts the boot" do
      ws =
        create_ws!("malformed-boot", %{
          "rig_paths" => %{"tonic" => "/srv/tonic"},
          "repo_paths" => "/srv/tonic"
        })

      capture_log(fn -> assert ConfigMigrator.start_link(primary?: true) == :ignore end)

      assert reload!(ws).config["repo_paths"] == %{"tonic" => "/srv/tonic"}
    end

    test "skips entirely and returns :ignore when not the primary instance" do
      ws = create_ws!("secondary", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.start_link(primary?: false) == :ignore
      assert reload!(ws).config["rig_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(reload!(ws).config, "repo_paths")
    end
  end
end
