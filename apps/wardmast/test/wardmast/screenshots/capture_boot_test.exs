defmodule Wardmast.Screenshots.CaptureBootTest do
  # Real boots: a fixture HTTP app (perl) is started from each commit's extracted tree, with the
  # command booter and the command-line Chromium shooter (a fake browser binary).
  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.Shooter.Chromium
  alias Wardmast.Screenshots.Config

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
      Keyword.merge([ctx: %{chrome: Path.join(@fixtures, "fake_chrome.sh")}], opts)
    )
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
