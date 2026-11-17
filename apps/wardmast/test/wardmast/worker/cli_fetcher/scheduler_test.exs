defmodule Wardmast.Worker.CliFetcher.SchedulerTest do
  use Wardmast.DataCase, async: false

  import Req.Test, only: [set_req_test_to_shared: 1]

  alias Wardmast.Settings
  alias Wardmast.Worker.CliFetcher.Cache
  alias Wardmast.Worker.CliFetcher.Fixtures
  alias Wardmast.Worker.CliFetcher.Scheduler

  @moduletag :tmp_dir

  setup :set_req_test_to_shared

  setup ctx do
    on_exit(fn ->
      Settings.set_worker_cli_versions(nil)
      Settings.set_worker_cli_set_hold(nil)
    end)

    # agy (bd-2esasx) is a code pin with its own archive URL and SHA-512.
    agy_archive = Fixtures.tgz([{"antigravity", "AGY-ELF", 0o755}])
    agy_path = "/antigravity-public/agy/cli_linux_x64.tar.gz"

    fetch_opts =
      Fixtures.base_opts(Path.join(ctx.tmp_dir, "cli-cache"),
        work_dir: ctx.tmp_dir,
        arb_version: "1.2.3",
        agy_releases: %{
          "1.5.9" => %{
            "linux-x64" =>
              {"https://storage.test" <> agy_path,
               Base.encode16(:crypto.hash(:sha512, agy_archive), case: :lower)}
          }
        }
      )

    routes =
      Fixtures.claude_routes(["2.1.308", "2.1.310"])
      |> Map.put(agy_path, {200, "application/gzip", agy_archive})
      |> Map.merge(Fixtures.codex_routes(["0.164.0"]))
      |> Map.merge(Fixtures.arb_routes("1.2.3"))

    Fixtures.serve(routes)
    {:ok, fetch_opts: fetch_opts}
  end

  defp start(ctx, extra \\ []) do
    opts =
      extra ++
        [
          name: nil,
          enabled: true,
          initial_delay_ms: :infinity,
          fill_delay_ms: :infinity,
          fetch_opts: ctx.fetch_opts
        ]

    start_supervised!({Scheduler, opts})
  end

  test "is off unless enabled" do
    assert :ignore = Scheduler.start_link(enabled: false, name: nil)
  end

  test "run_now bumps the pins, caches every CLI including arb, and reports", ctx do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert report.bump["claude"] == {:bumped, "2.1.308", "2.1.310"}
    assert report.bump["codex"] == {:current, "0.164.0"}
    assert report.ensured == %{"claude" => :ok, "codex" => :ok, "agy" => :ok, "arb" => :ok}

    for {name, version} <- [
          {"claude", "2.1.310"},
          {"codex", "0.164.0"},
          {"agy", "1.5.9"},
          {"arb", "1.2.3"}
        ] do
      assert {:ok, _} = Cache.lookup(name, version, ctx.fetch_opts)
    end

    status = Scheduler.status(pid)
    assert status.enabled
    assert status.latest == %{"claude" => "2.1.310", "codex" => "0.164.0"}
    assert %DateTime{} = status.checked_at
  end

  test "the boot fill caches the pinned CLIs without waiting for the daily run", ctx do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    pid = start(ctx)

    # The boot timer's message, sent by hand; the task it starts is awaited by its pid.
    send(pid, :fill)
    %Task{pid: task} = :sys.get_state(pid).task
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    _ = :sys.get_state(pid)

    assert Scheduler.status(pid).ensured == %{
             "claude" => :ok,
             "codex" => :ok,
             "agy" => :ok,
             "arb" => :ok
           }

    for {name, version} <- [
          {"claude", "2.1.308"},
          {"codex", "0.164.0"},
          {"agy", "1.5.9"},
          {"arb", "1.2.3"}
        ] do
      assert {:ok, _} = Cache.lookup(name, version, ctx.fetch_opts)
    end

    # It is not the daily job: nothing was bumped and no check is recorded.
    status = Scheduler.status(pid)
    assert status.checked_at == nil
    assert Settings.worker_cli_versions()["claude"] == "2.1.308"
  end

  test "while held it still reports what is available but changes nothing", ctx do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert report.bump["claude"] == {:held, "a1b2c3d4"}
    assert Settings.worker_cli_versions()["claude"] == "2.1.308"
    assert Scheduler.status(pid).latest["claude"] == "2.1.310"
  end

  test "an upstream failure is reported, not raised", ctx do
    Fixtures.serve(%{})
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert {:error, _} = report.bump["claude"]
    assert Process.alive?(pid)
    assert Scheduler.status(pid).latest == %{"claude" => nil, "codex" => nil}
  end

  test "status/1 of a scheduler that is not running
 is a disabled placeholder" do
    assert %{enabled: false, checked_at: nil} = Scheduler.status(:nonexistent_cli_scheduler)
  end
end
