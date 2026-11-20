defmodule Wardmast.Screenshots.CaptureServicesTest do
  @moduledoc """
  `Capture.run/2` with capture services and the offline deps cache (bd-3glf2a), against stub
  services, booter, shooter and deps cache: every boot gets fresh services, started before the
  app and stopped after it on every exit path; a service that does not come up is a `boot_failed`
  carrying its log tail and nothing boots; a head that changes `mix.lock` is skipped.
  """

  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CaptureHostSandbox
  alias Wardmast.Test.CaptureStubBooter
  alias Wardmast.Test.CaptureStubDeps
  alias Wardmast.Test.CaptureStubServices
  alias Wardmast.Test.CaptureStubShooter

  @moduletag :tmp_dir

  @pg %{
    name: "postgres",
    image: "postgis/postgis:16-3.4",
    port: 5432,
    env: [],
    command: [],
    ready: %{kind: :tcp, timeout_seconds: 60},
    socket: nil
  }

  @config %Config{ui_paths: ["web/**"], start_cmd: "true", services: [@pg]}

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp repo!(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "web"))
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "web/page.txt"), "v1")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "web/page.txt"), "v2")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "head"])
    {repo, base, git!(repo, ["rev-parse", "HEAD"])}
  end

  defp plan!(dir, shots) do
    path = Path.join(dir, "screenshots.json")
    File.write!(path, Jason.encode!(%{"version" => 1, "shots" => shots}))
    path
  end

  defp run(dir, plan, opts \\ []) do
    {repo, base, head} = repo!(dir)
    {config, opts} = Keyword.pop(opts, :config, @config)
    {ctx_extra, opts} = Keyword.pop(opts, :ctx, %{})
    {services_opts, opts} = Keyword.pop(opts, :services_opts, [])

    Capture.run(
      %{
        task_id: "bd-test",
        repo_path: repo,
        base_sha: base,
        head_sha: head,
        config: config,
        plan_path: plan,
        out_dir: Path.join(dir, "out")
      },
      Keyword.merge(
        [
          booter: CaptureStubBooter,
          shooter: CaptureStubShooter,
          sandbox: CaptureHostSandbox,
          services: CaptureStubServices,
          services_opts: [test_pid: self()] ++ services_opts,
          deps: CaptureStubDeps,
          deps_opts: [test_pid: self()],
          ctx:
            Map.merge(
              %{test_pid: self(), routes: %{"before" => %{"/" => 200}, "after" => %{"/" => 200}}},
              ctx_extra
            )
        ],
        opts
      )
    )
  end

  # The boot lifecycle as the stubs saw it, in order.
  defp lifecycle do
    {:messages, msgs} = Process.info(self(), :messages)

    for msg <- msgs, elem(msg, 0) in [:services_start, :services_stop, :boot, :stop] do
      case msg do
        {:services_start, role, _names, handle} -> {:services_start, role, handle}
        {:services_stop, handle} -> {:services_stop, handle}
        {:boot, role, _seed, _checkout} -> {:boot, role}
        {:stop, role, _seed} -> {:stop, role}
      end
    end
  end

  defp manifest(dir), do: dir |> Path.join("out/capture.json") |> File.read!() |> Jason.decode!()

  describe "services" do
    test "every boot gets its own, started before the app and stopped after it", %{tmp_dir: dir} do
      assert {:ok, _} = run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]))

      assert [
               {:services_start, "before", before},
               {:boot, "before"},
               {:stop, "before"},
               {:services_stop, before},
               {:services_start, "after", after_boot},
               {:boot, "after"},
               {:stop, "after"},
               {:services_stop, after_boot}
             ] = lifecycle()

      refute before == after_boot
    end

    test "the services get the capture's budget, so no wait for one outlives it", %{tmp_dir: dir} do
      before = System.monotonic_time(:millisecond)

      assert {:ok, _} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]), budget_seconds: 300)

      assert_received {:services_deadline, "before", deadline}
      assert is_integer(deadline)

      assert deadline >= before + 299_000 and
               deadline <= System.monotonic_time(:millisecond) + 300_000
    end

    test "the boot is handed each service's endpoint", %{tmp_dir: dir} do
      assert {:ok, _} = run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]))

      assert_received {:boot_spec, "before",
                       [%{name: "postgres", port: 5432, socket: "/sock/before/postgres"}], nil}

      assert_received {:boot_spec, "after",
                       [%{name: "postgres", port: 5432, socket: "/sock/after/postgres"}], nil}
    end

    test "a named-seed boot gets fresh services too", %{tmp_dir: dir} do
      config = %{@config | seeds: %{"empty" => "true"}}

      plan =
        plan!(dir, [
          %{"id" => "home", "path" => "/"},
          %{"id" => "e", "path" => "/", "seed" => "empty"}
        ])

      assert {:ok, _} = run(dir, plan, config: config)

      starts = for {:services_start, role, handle} <- lifecycle(), do: {role, handle}
      assert Enum.map(starts, &elem(&1, 0)) == ["before", "before", "after", "after"]
      assert length(Enum.uniq_by(starts, &elem(&1, 1))) == 4
    end

    test "no services configured: none are started", %{tmp_dir: dir} do
      config = %{@config | services: []}
      assert {:ok, _} = run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]), config: config)
      assert for({:services_start, _, _} <- lifecycle(), do: 1) == []
      assert_received {:boot_spec, "before", [], nil}
    end
  end

  describe "services are removed on every exit path" do
    test "the app failing to boot", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :boot_failed}} =
               run(dir, plan, ctx: %{boot_failures: %{"before" => "exit 1"}})

      assert [{:services_start, "before", h}, {:boot, "before"}, {:services_stop, h}] =
               lifecycle()
    end

    test "a shot failing", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :shot_failed}} =
               run(dir, plan, ctx: %{shoot_error: {:shot, "browser crashed"}})

      assert [
               {:services_start, "before", h},
               {:boot, "before"},
               {:stop, "before"},
               {:services_stop, h}
             ] = lifecycle()
    end

    test "the shooter raising", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])
      assert {:error, _} = run(dir, plan, ctx: %{shoot_raise: "boom"})
      assert {:services_stop, _} = List.last(lifecycle())
    end

    test "a stop that exits does not take the capture's result with it", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:ok, %{pairs: [_]}} =
               run(dir, plan, services_opts: [stop_exit: :podman_vanished])

      assert {:services_stop, _} = List.last(lifecycle())
    end

    test "the budget running out after the boot", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :budget_exceeded}} =
               run(dir, plan, budget_seconds: 1, ctx: %{boot_delay_ms: 1_100})

      assert [
               {:services_start, "before", h},
               {:boot, "before"},
               {:stop, "before"},
               {:services_stop, h}
             ] = lifecycle()
    end
  end

  describe "a service that does not come up" do
    @failure %{
      service: "postgres",
      reason: "did not become ready in 60 s (last check: exit 2)",
      log_tail: "FATAL:  data directory has wrong ownership"
    }

    test "fails the boot with its log tail, recorded in capture.json, and boots nothing", %{
      tmp_dir: dir
    } do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, failure} =
               run(dir, plan, services_opts: [fail: %{"before" => @failure}])

      assert failure.code == :boot_failed
      assert failure.role == "before"
      assert failure.message =~ "postgres"
      assert failure.message =~ "did not become ready in 60 s"
      assert failure.message =~ "FATAL:  data directory has wrong ownership"

      # Nothing ran: no boot (no setup, no app), no shot, no head boot.
      assert [{:services_start, "before", _}] = lifecycle()
      refute_received {:shoot, _, _, _, _}

      recorded = manifest(dir)
      assert recorded["state"] == "failed"
      assert recorded["failure"]["code"] == "boot_failed"
      assert recorded["failure"]["message"] =~ "FATAL:  data directory has wrong ownership"
      assert recorded["failure"]["detail"] =~ "FATAL:  data directory has wrong ownership"
    end

    test "a services provider that exits is a boot failure too, not a crash", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :boot_failed, role: "before"} = failure} =
               run(dir, plan, services_opts: [fail: %{"before" => {:exit, :podman_vanished}}])

      assert failure.message =~ "podman_vanished"
      assert [{:services_start, "before", _}] = lifecycle()
    end

    test "a log tail that is not UTF-8 still makes a readable capture.json", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])
      failure = %{@failure | log_tail: <<0xFF, 0xFE>> <> "FATAL:  broken \xC3"}

      assert {:error, %{code: :boot_failed}} =
               run(dir, plan, services_opts: [fail: %{"before" => failure}])

      recorded = manifest(dir)
      assert recorded["failure"]["code"] == "boot_failed"
      assert recorded["failure"]["message"] =~ "FATAL:  broken"
      assert String.valid?(recorded["failure"]["message"])
    end

    test "at the head, after the base was shot", %{tmp_dir: dir} do
      plan = plan!(dir, [%{"id" => "home", "path" => "/"}])

      assert {:error, %{code: :boot_failed, role: "after"}} =
               run(dir, plan, services_opts: [fail: %{"after" => @failure}])

      assert {:services_start, "after", _} = List.last(lifecycle())
    end
  end

  describe "the offline deps cache" do
    test "off unless deps.mix: the deps cache is never asked", %{tmp_dir: dir} do
      assert {:ok, _} = run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]))
      refute_received {:deps_prepare, _}
    end

    test "a head that changes mix.lock is skipped (deps_changed) before anything boots", %{
      tmp_dir: dir
    } do
      config = %{@config | deps: %{"mix" => true}}
      reason = "the change edits mix.lock"

      assert {:skipped, {:deps_changed, ^reason}} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:skip, reason}]
               )

      assert lifecycle() == []
      assert manifest(dir)["skip_kind"] == "deps_changed"
      assert manifest(dir)["skip"] == reason
    end

    test "the cache it returns is handed to every boot", %{tmp_dir: dir} do
      config = %{@config | deps: %{"mix" => true}}
      cache = %{dir: "/cache/abc", env: [{"HEX_OFFLINE", "1"}], links: []}

      assert {:ok, _} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:ok, cache}]
               )

      assert_received {:deps_prepare, input}
      assert input.base_sha =~ ~r/\A[0-9a-f]{40}\z/
      assert input.default_branch == "main"
      assert input.sandbox == CaptureHostSandbox
      assert_received {:boot_spec, "before", _, ^cache}
      assert_received {:boot_spec, "after", _, ^cache}
    end

    # bd-ur1zty: the seed is built from the config's own values, under the boot's MIX_ENV.
    test "the seed is asked for the boot's MIX_ENV and the config's own env", %{tmp_dir: dir} do
      config = %{
        @config
        | deps: %{"mix" => true, "env" => %{"SECRET_KEY_BASE" => "dummy"}},
          env: %{"MIX_ENV" => "test", "DATABASE_URL" => "ecto://127.0.0.1/capture"}
      }

      assert {:ok, _} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:ok, nil}]
               )

      assert_received {:deps_prepare, input}
      assert input.mix_env == "test"

      assert Enum.sort(input.seed_env) ==
               [{"DATABASE_URL", "ecto://127.0.0.1/capture"}, {"SECRET_KEY_BASE", "dummy"}]
    end

    test "a deps cache that exits is deps_failed, not a crash", %{tmp_dir: dir} do
      config = %{@config | deps: %{"mix" => true}}

      assert {:error, %{code: :deps_failed} = failure} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:exit, :global_lock_lost}]
               )

      assert failure.message =~ "global_lock_lost"
      assert lifecycle() == []
    end

    # bd-5eegxz: a capture that cannot run for this change (its lockfile, or the cache) must
    # say so, not fault the worker's missing manifest: the worker could not fix that.
    test "a missing manifest does not hide a deps_changed skip", %{tmp_dir: dir} do
      config = %{@config | deps: %{"mix" => true}}
      reason = "the change edits mix.lock"

      assert {:skipped, {:deps_changed, ^reason}} =
               run(dir, Path.join(dir, "nope.json"),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:skip, reason}]
               )

      assert manifest(dir)["skip_kind"] == "deps_changed"
      assert manifest(dir)["reason"] == reason
    end

    test "an invalid manifest does not hide a deps failure", %{tmp_dir: dir} do
      config = %{@config | deps: %{"mix" => true}}
      bad = Path.join(dir, "bad.json")
      File.write!(bad, ~s({"version": 9}))

      assert {:error, %{code: :deps_failed}} =
               run(dir, bad,
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:error, "nxdomain"}]
               )
    end

    test "with a deps cache that is fine, the missing manifest is still the worker's", %{
      tmp_dir: dir
    } do
      config = %{@config | deps: %{"mix" => true}}

      assert {:error, %{code: :manifest_missing}} =
               run(dir, Path.join(dir, "nope.json"),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:ok, nil}]
               )
    end

    test "a cache that cannot be built is an infrastructure failure, before any boot", %{
      tmp_dir: dir
    } do
      config = %{@config | deps: %{"mix" => true}}

      assert {:error, failure} =
               run(dir, plan!(dir, [%{"id" => "home", "path" => "/"}]),
                 config: config,
                 deps_opts: [test_pid: self(), answer: {:error, "mix deps.get failed: nxdomain"}]
               )

      assert failure.code == :deps_failed
      assert failure.message =~ "nxdomain"
      assert lifecycle() == []
    end
  end
end
