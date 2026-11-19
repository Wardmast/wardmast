defmodule Wardmast.Screenshots.CaptureBootTest do
  # Real boots: a fixture HTTP app (perl) is started from each commit's extracted tree, with the
  # command booter and the command-line Chromium shooter (a fake browser binary). These tests are
  # about the boot, so they run under `CaptureHostSandbox` (no isolation, test support only); the
  # isolation itself is `capture_sandbox_test.exs`, against a real bwrap.
  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.Booter
  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap
  alias Wardmast.Screenshots.Capture.Shooter.Chromium
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CaptureHostSandbox

  @moduletag :tmp_dir

  @fixtures Path.expand("../../fixtures/screenshots_app", __DIR__)

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  # Commits the fixture app with `base_routes`, then `head_routes` (plus a UI-path touch).
  defp repo!(dir, base_routes, head_routes) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.cp!(Path.join(@fixtures, "app.pl"), Path.join(repo, "app.pl"))
    File.cp!(Path.join(@fixtures, "endless_app.pl"), Path.join(repo, "endless_app.pl"))
    File.write!(Path.join(repo, "routes.txt"), Enum.join(base_routes, "\n"))
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "routes.txt"), Enum.join(head_routes, "\n"))
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "head"])
    {repo, base, git!(repo, ["rev-parse", "HEAD"])}
  end

  defp config(overrides \\ %{}) do
    struct!(
      Config,
      Map.merge(
        %{
          ui_paths: ["routes.txt"],
          start_cmd: "perl app.pl",
          port_range: {33_000, 33_400},
          ready: %{"path" => "/", "timeout_seconds" => 20, "expect" => "below_500"}
        },
        overrides
      )
    )
  end

  defp plan!(dir, shots) do
    path = Path.join(dir, "screenshots.json")
    File.write!(path, Jason.encode!(%{"version" => 1, "shots" => shots}))
    path
  end

  defp run(dir, {repo, base, head}, plan, cfg, opts \\ []) do
    Capture.run(
      %{
        task_id: "bd-boot",
        repo_path: repo,
        base_sha: base,
        head_sha: head,
        config: cfg,
        plan_path: plan,
        out_dir: Path.join(dir, "out")
      },
      Keyword.merge(
        [ctx: %{chrome: Path.join(@fixtures, "fake_chrome.sh")}, sandbox: CaptureHostSandbox],
        opts
      )
    )
  end

  # A stand-in browser: `body` is shell run with `$out` set to the --screenshot target.
  defp fake_browser!(dir, name, body) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        --screenshot=*) out="${a#--screenshot=}" ;;
      esac
    done
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Kill the process group whose id a boot recorded in `file`, if any member is still alive. The
  # id is pinned while a member exists, so this can only ever reach that boot's processes.
  defp kill_group(file) do
    pgid = file |> File.read!() |> String.trim()

    with true <- pgid =~ ~r/\A[1-9][0-9]*\z/,
         {_, 0} <- System.cmd("kill", ["-0", "--", "-" <> pgid], stderr_to_stdout: true) do
      System.cmd("kill", ["-KILL", "--", "-" <> pgid], stderr_to_stdout: true)
    end
  end

  defp put_envs(pairs) do
    saved = Map.new(pairs, fn {k, _} -> {k, Application.fetch_env(:wardmast, k)} end)

    Enum.each(pairs, fn
      {k, :delete} -> Application.delete_env(:wardmast, k)
      {k, v} -> Application.put_env(:wardmast, k, v)
    end)

    Bwrap.reset()

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:wardmast, k, v)
        {k, :error} -> Application.delete_env(:wardmast, k)
      end)

      Bwrap.reset()
    end)
  end

  test "boots the fixture app at each commit and pairs the shots", %{tmp_dir: dir} do
    repo = repo!(dir, ["/", "/old"], ["/", "/new"])

    plan =
      plan!(dir, [
        %{"id" => "home", "path" => "/"},
        %{"id" => "fresh", "path" => "/new"},
        %{"id" => "gone", "path" => "/old"}
      ])

    assert {:ok, result} = run(dir, repo, plan, config())
    by_id = Map.new(result.pairs, &{&1.id, &1})

    assert by_id["home"].kind == :changed
    assert File.read!(by_id["home"].before.file) =~ "IMG http://127.0.0.1:"
    assert File.read!(by_id["home"].after.file) =~ "/"
    assert by_id["fresh"].kind == :new
    assert by_id["gone"].kind == :removed
    assert File.exists?(result.manifest_path)
    assert Enum.map(result.boots, & &1["role"]) == ["before", "after"]
  end

  test "the app is not left running", %{tmp_dir: dir} do
    repo = repo!(dir, ["/"], ["/", "/x"])
    parent = self()

    cfg =
      config(%{
        start_cmd: "echo $PORT > {{scratch}}/port.txt; exec perl app.pl",
        port_range: {33_410, 33_420}
      })

    # Record each boot's port by reading the file the start command wrote.
    assert {:ok, _} =
             run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg,
               record: fn event -> send(parent, {:event, event}) end
             )

    assert_received {:event, %{state: :ok}}

    # Both ports are free again: nothing is listening.
    for port <- 33_410..33_420 do
      assert {:error, _} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 200)
    end
  end

  test "setup and seed run per boot with a scrubbed environment", %{tmp_dir: dir} do
    System.put_env("ARB_CAPTURE_TEST_SECRET", "hunter2")
    on_exit(fn -> System.delete_env("ARB_CAPTURE_TEST_SECRET") end)
    repo = repo!(dir, ["/"], ["/", "/x"])
    marks = Path.join(dir, "marks")
    File.mkdir_p!(marks)

    cfg =
      config(%{
        setup_cmd: "echo setup-{{role}} >> #{marks}/setup.txt; env > #{marks}/env-{{role}}.txt",
        seed_cmd: "echo seed-{{role}} >> #{marks}/seed.txt",
        env: %{"APP_FLAG" => "{{role}}"}
      })

    assert {:ok, _} = run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

    assert File.read!(Path.join(marks, "setup.txt")) == "setup-before\nsetup-after\n"
    assert File.read!(Path.join(marks, "seed.txt")) == "seed-before\nseed-after\n"
    env = File.read!(Path.join(marks, "env-before.txt"))
    assert env =~ "APP_FLAG=before"
    assert env =~ "PORT="
    refute env =~ "hunter2"
    refute env =~ "ARB_CAPTURE_TEST_SECRET"
  end

  test "the boot PATH drops the release bin dirs", %{tmp_dir: dir} do
    release_root = Path.join(dir, "fake-release")
    old_root = System.get_env("RELEASE_ROOT")
    old_path = System.get_env("PATH")
    System.put_env("RELEASE_ROOT", release_root)
    System.put_env("PATH", "#{release_root}/erts-1/bin:#{release_root}/bin:#{old_path}")

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if old_root,
        do: System.put_env("RELEASE_ROOT", old_root),
        else: System.delete_env("RELEASE_ROOT")
    end)

    repo = repo!(dir, ["/"], ["/", "/x"])
    marks = Path.join(dir, "marks")
    File.mkdir_p!(marks)
    cfg = config(%{setup_cmd: "env > #{marks}/env-{{role}}.txt"})

    assert {:ok, _} = run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

    env = File.read!(Path.join(marks, "env-before.txt"))
    assert env =~ ~r/^PATH=/m
    refute env =~ release_root
  end

  describe "failure reasons" do
    test "a start command that dies is a boot failure at that commit", %{tmp_dir: dir} do
      repo = repo!(dir, ["/"], ["/", "/x"])
      cfg = config(%{start_cmd: "echo kaboom; exit 3"})

      assert {:error, failure} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

      assert failure.code == :boot_failed
      assert failure.role == "before"
      assert failure.message =~ "status 3"
      assert failure.message =~ "kaboom"
    end

    test "a failing setup command is a boot failure", %{tmp_dir: dir} do
      repo = repo!(dir, ["/"], ["/", "/x"])
      cfg = config(%{setup_cmd: "echo no-deps >&2; exit 1"})

      assert {:error, %{code: :boot_failed, detail: %{phase: :setup}} = failure} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

      assert failure.message =~ "no-deps"
    end

    test "an app that never answers is a boot failure after the ready timeout", %{tmp_dir: dir} do
      repo = repo!(dir, ["/"], ["/", "/x"])

      cfg =
        config(%{
          start_cmd: "sleep 30",
          ready: %{"path" => "/", "timeout_seconds" => 1, "expect" => "below_500"}
        })

      assert {:error, %{code: :boot_failed, detail: %{phase: :ready}}} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)
    end

    test "a route that answers 500 is a route error", %{tmp_dir: dir} do
      repo = repo!(dir, ["/", "/boom"], ["/", "/boom", "/x"])

      assert {:error, failure} =
               run(dir, repo, plan!(dir, [%{"id" => "bad", "path" => "/boom"}]), config())

      assert failure.code == :route_error
      assert failure.shot == "bad"
      assert failure.message =~ "500"
    end

    test "steps the command-line shooter cannot run are reported, not skipped", %{tmp_dir: dir} do
      repo = repo!(dir, ["/"], ["/", "/x"])

      plan =
        plan!(dir, [
          %{
            "id" => "modal",
            "path" => "/",
            "steps" => [%{"action" => "click", "selector" => "#a"}]
          }
        ])

      assert {:error, %{code: :shot_failed} = failure} = run(dir, repo, plan, config())
      assert failure.message =~ "steps"
    end

    test "no browser installed is a shot failure with the reason", %{tmp_dir: dir} do
      repo = repo!(dir, ["/"], ["/", "/x"])

      assert {:error, %{code: :shot_failed} = failure} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), config(),
                 ctx: %{chrome: "/nonexistent/chrome"}
               )

      assert failure.message =~ "Chromium"
    end
  end

  test "the app gets a HOME of its own, inside the boot scratch", %{tmp_dir: dir} do
    repo = repo!(dir, ["/"], ["/", "/x"])
    marks = Path.join(dir, "marks")
    File.mkdir_p!(marks)

    cfg =
      config(%{
        setup_cmd:
          "env > #{marks}/env-{{role}}.txt; test -d \"$HOME\" && echo ok > #{marks}/home-{{role}}"
      })

    assert {:ok, _} = run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

    env = File.read!(Path.join(marks, "env-before.txt"))
    assert env =~ ~r{^HOME=.*/work/before/scratch-default/home$}m
    refute env =~ ~r{^HOME=#{Regex.escape(System.user_home!())}$}m
    assert File.read!(Path.join(marks, "home-before")) == "ok\n"
  end

  test "an app whose body never ends is probed and shot by its status alone", %{tmp_dir: dir} do
    repo = repo!(dir, ["/"], ["/", "/x"])
    pids = Path.join(dir, "pids")
    File.mkdir_p!(pids)

    # Each boot records its process group (the shell `exec`s the app, so `$$` is the group
    # AppProcess leads); whatever the outcome, that exact group is gone after the test.
    on_exit(fn -> pids |> Path.join("*.pid") |> Path.wildcard() |> Enum.each(&kill_group/1) end)

    cfg =
      config(%{
        start_cmd: "echo $$ > #{pids}/{{role}}.pid; exec perl endless_app.pl",
        ready: %{"path" => "/", "timeout_seconds" => 15, "expect" => "below_500"}
      })

    started = System.monotonic_time(:millisecond)

    # Reading the body would never end; the readiness probe and the status check stop at the
    # status. (A probe that read it would only wait out its timeouts: the fixture trickles.)
    assert {:ok, %{pairs: [%{kind: :changed}]}} =
             run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg)

    assert System.monotonic_time(:millisecond) - started < 15_000
  end

  describe "the browser (bd-bhrsdv)" do
    test "runs with an environment built from nothing", %{tmp_dir: dir} do
      System.put_env("ARB_CAPTURE_TEST_SECRET", "hunter2")
      on_exit(fn -> System.delete_env("ARB_CAPTURE_TEST_SECRET") end)
      repo = repo!(dir, ["/"], ["/", "/x"])
      browser = fake_browser!(dir, "env_chrome.sh", ~s(env > "$out"))

      assert {:ok, %{pairs: [pair]}} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), config(),
                 ctx: %{chrome: browser}
               )

      env = File.read!(pair.after.file)
      assert env =~ ~r/^TZ=UTC$/m
      assert env =~ ~r/^HOME=/m
      refute env =~ "hunter2"
      refute env =~ "ARB_CAPTURE_TEST_SECRET"
      # Chromium puts its singleton socket under TMPDIR, and sun_path is 108 bytes: the shot's own
      # deep directory aborted a real Chromium ("Socket path too long"). /tmp is short, and
      # private to each browser in the bwrap sandbox.
      assert env =~ ~r{^TMPDIR=/tmp$}m
    end

    test "writes into its own directory; a symlink it leaves there is never followed", %{
      tmp_dir: dir
    } do
      canary = Path.join(dir, "host-secret.txt")
      File.write!(canary, "host secret")
      repo = repo!(dir, ["/"], ["/", "/x"])
      browser = fake_browser!(dir, "link_chrome.sh", ~s(ln -s "#{canary}" "$out"))

      assert {:error, failure} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), config(),
                 ctx: %{chrome: browser}
               )

      assert failure.code == :shot_failed
      assert failure.message =~ "no image"
      images = Path.join([dir, "out", "images"])

      for file <- Path.wildcard(Path.join(images, "*")) do
        refute File.read!(file) =~ "host secret"
      end
    end
  end

  describe "fail closed: never unsandboxed (bd-bhrsdv)" do
    test "a host where bwrap is missing skips the capture and runs nothing", %{tmp_dir: dir} do
      put_envs(
        capture_sandbox_available: :delete,
        capture_sandbox_bwrap: Path.join(dir, "no-such-bwrap")
      )

      repo = repo!(dir, ["/"], ["/", "/x"])
      marks = Path.join(dir, "marks")
      File.mkdir_p!(marks)

      cfg =
        config(%{
          setup_cmd: "touch #{marks}/setup-ran",
          seed_cmd: "touch #{marks}/seed-ran",
          start_cmd: "touch #{marks}/app-ran; exec perl app.pl"
        })

      browser = fake_browser!(dir, "marking_chrome.sh", ~s(touch "#{marks}/browser-ran"))

      assert {:skipped, {:no_sandbox, reason}} =
               run(dir, repo, plan!(dir, [%{"id" => "home", "path" => "/"}]), cfg,
                 sandbox: Bwrap,
                 ctx: %{chrome: browser}
               )

      assert reason =~ "capture needs a sandbox"
      assert reason =~ "bwrap"
      assert File.ls!(marks) == []
      refute File.exists?(Path.join([dir, "out", "images"]))
    end

    test "the command booter refuses to run a command without a sandbox", %{tmp_dir: dir} do
      marks = Path.join(dir, "marks")
      File.mkdir_p!(marks)

      spec = %{
        role: "before",
        checkout: dir,
        scratch: Path.join(dir, "scratch"),
        seed: nil,
        config: config(%{setup_cmd: "touch #{marks}/ran", start_cmd: "touch #{marks}/ran"}),
        task_id: "bd-boot",
        ctx: nil
      }

      assert {:error, {:start, message}} = Booter.Command.boot(spec)
      assert message =~ "sandbox"
      assert File.ls!(marks) == []
    end

    test "the Chromium shooter refuses to start a browser without a sandbox", %{tmp_dir: dir} do
      marks = Path.join(dir, "marks")
      File.mkdir_p!(marks)
      browser = fake_browser!(dir, "marking_chrome.sh", ~s(touch "#{marks}/browser-ran"))
      out = Path.join(dir, "x.png")

      spec = %{
        role: "after",
        base_url: "http://127.0.0.1:1",
        path: "/",
        entry: %{
          id: "home",
          steps: [],
          wait_for: nil,
          target: nil,
          full_page: false,
          hide: [],
          as: nil
        },
        out_file: out,
        config: config(),
        viewport: %{"width" => 800, "height" => 600},
        theme: %{"color_scheme" => "light"},
        timeout_s: 5,
        scratch: Path.join(dir, "shot"),
        ctx: %{chrome: browser}
      }

      assert {:error, {:shot, message}} = Chromium.shoot(spec)
      assert message =~ "sandbox"
      assert File.ls!(marks) == []
      refute File.exists?(out)
    end
  end

  test "argv carries the viewport, scale, colour scheme and url" do
    spec = %{
      viewport: %{"width" => 390, "height" => 844, "device_scale_factor" => 2},
      theme: %{"color_scheme" => "dark", "query" => %{"theme" => "dark"}},
      out_file: "/o/x.png",
      base_url: "http://127.0.0.1:1",
      path: "/a?b=1"
    }

    argv = Chromium.argv(spec, "/p")
    assert "--window-size=390,844" in argv
    assert "--force-device-scale-factor=2" in argv
    assert "--blink-settings=preferredColorScheme=1" in argv
    assert "--screenshot=/o/x.png" in argv
    assert List.last(argv) == "http://127.0.0.1:1/a?b=1&theme=dark"
  end
end
