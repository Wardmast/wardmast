defmodule Wardmast.Screenshots.CaptureSandboxTest do
  @moduledoc """
  The capture sandbox for real (bd-bhrsdv): a full `Capture.run/2` with the command booter and
  the Chromium shooter under `Capture.Sandbox.Bwrap`, booting a probe app
  (`test/fixtures/screenshots_app/probe_app.pl`) and a stand-in browser (`probe_chrome.pl`)
  that each try every way out the sandbox must close:

    * a TCP listener on host loopback, standing in for the coordinator's port (`:4848` on the
      dogfood host), which an unsandboxed control reaches first, so the probe is not vacuous;
    * an external address (no route at all: "Network is unreachable") and an external name;
    * a file next to the capture's own directories, and a write outside its tree;
    * the host's processes (the test VM's pid).

  bd-3glf2a adds a capture service (a stand-in for `Services.Podman`'s host socket), which setup
  and the app reach on `127.0.0.1:<port>` and at its declared socket path and by no other route
  (not on host loopback, not beside its socket, not from the browser), and a boot that compiles
  from the offline deps cache inside the sandbox.

  Needs a working bwrap (skipped elsewhere, like the jail tests; CI's `jail` job sets
  `WARDMAST_TEST_REQUIRE_BWRAP=1`, which turns the skip into a failure).
  """

  use ExUnit.Case, async: false

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.DepsCache
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap
  alias Wardmast.Screenshots.Config
  alias Wardmast.Test.CaptureHostServices
  alias Wardmast.Test.JailProbe

  # Needs Linux namespaces and a real bwrap.
  @moduletag :linux
  @moduletag :tmp_dir

  @bwrap_skip JailProbe.skip_reason(Bwrap.probe(), "the capture sandbox (bwrap)")
  if @bwrap_skip, do: @moduletag(skip: @bwrap_skip)

  @fixtures Path.expand("../../fixtures/screenshots_app", __DIR__)

  setup do
    saved = Application.fetch_env(:wardmast, :capture_sandbox_available)
    # config/test.exs turns the sandbox off for every other test; this module is gated on the
    # real probe above, so let `status/0` say yes.
    Application.put_env(:wardmast, :capture_sandbox_available, true)
    System.put_env("ARB_CAPTURE_TEST_SECRET", "hunter2")

    on_exit(fn ->
      System.delete_env("ARB_CAPTURE_TEST_SECRET")

      case saved do
        {:ok, v} -> Application.put_env(:wardmast, :capture_sandbox_available, v)
        :error -> Application.delete_env(:wardmast, :capture_sandbox_available)
      end
    end)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp repo!(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.cp!(Path.join(@fixtures, "probe_app.pl"), Path.join(repo, "probe_app.pl"))
    File.write!(Path.join(repo, "routes.txt"), "/")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "routes.txt"), "/\n/x")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "head"])
    {repo, base, git!(repo, ["rev-parse", "HEAD"])}
  end

  # The stand-in browser lives in its own directory (the sandbox shows the browser's install
  # dir), with the coordinator port and the canary path beside it.
  defp browser!(dir, coordinator, canary, service_port \\ nil) do
    bin = Path.join(dir, "browser")
    File.mkdir_p!(bin)
    chrome = Path.join(bin, "chrome")
    File.cp!(Path.join(@fixtures, "probe_chrome.pl"), chrome)
    File.chmod!(chrome, 0o755)
    File.write!(Path.join(bin, "coordinator_port"), Integer.to_string(coordinator))
    File.write!(Path.join(bin, "canary_path"), canary)

    if service_port,
      do: File.write!(Path.join(bin, "service_port"), Integer.to_string(service_port))

    chrome
  end

  defp cap_dirs, do: Path.wildcard(Path.join(Paths.socket_root(), "cap-*"))

  test "the app and the browser reach neither the coordinator's port, an external host, nor host files",
       %{tmp_dir: dir} do
    # The "coordinator": a real listener on host loopback.
    {:ok, coordinator} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(coordinator)

    # Control: the same probe, unsandboxed, does reach it.
    {control, 0} =
      System.cmd("perl", [Path.join(@fixtures, "probe_app.pl"), "--probe", "127.0.0.1", "#{port}"])

    assert String.trim(control) == "connected"
    assert {:ok, peer} = :gen_tcp.accept(coordinator, 2_000)
    :gen_tcp.close(peer)

    canary = Path.join(dir, "host-only.txt")
    File.write!(canary, "patient record")
    cap_dirs_before = cap_dirs()

    config =
      struct!(Config, %{
        ui_paths: ["routes.txt"],
        setup_cmd: "perl probe_app.pl --probe 127.0.0.1 #{port} > setup-probe.txt",
        start_cmd: "exec perl probe_app.pl",
        port_range: {33_500, 33_600},
        env: %{
          "PROBE_COORDINATOR_PORT" => Integer.to_string(port),
          "PROBE_CANARY" => canary,
          "PROBE_HOST_PID" => System.pid()
        },
        ready: %{"path" => "/", "timeout_seconds" => 30, "expect" => "below_500"}
      })

    plan = Path.join(dir, "screenshots.json")
    File.write!(plan, ~s({"version": 1, "shots": [{"id": "home", "path": "/"}]}))
    {repo, base, head} = repo!(dir)

    assert {:ok, %{pairs: [pair]}} =
             Capture.run(
               %{
                 task_id: "bd-sandbox",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 config: config,
                 plan_path: plan,
                 out_dir: Path.join(dir, "out")
               },
               sandbox: Bwrap,
               ctx: %{chrome: browser!(dir, port, canary)}
             )

    for side <- [pair.before, pair.after] do
      shot = File.read!(side.file)
      JailProbe.evidence("capture sandbox #{Path.basename(side.file)}", shot)

      # The browser loaded the app through the sandbox's bridge...
      assert shot =~ "HTTP/1.1 200 OK"

      # ...and from inside, host loopback is an empty namespace's loopback and the outside world
      # has no route at all: refused and unreachable, not a firewall timing out.
      assert shot =~ "\ncoordinator=failed: Connection refused"
      assert shot =~ "\nsetup_coordinator=failed: Connection refused"
      assert shot =~ "\nBROWSER coordinator=failed: Connection refused"
      assert shot =~ "\nexternal_ip=failed: Network is unreachable"
      assert shot =~ "\nBROWSER external_ip=failed: Network is unreachable"
      assert shot =~ ~r/\nexternal_name=failed: /
      assert shot =~ ~r/\nBROWSER external_name=failed: /

      # No ambient filesystem: a host file beside the capture is not there, the system is
      # read-only, and only the app's own checkout and scratch take writes.
      assert shot =~ "\ncanary=failed: No such file or directory"
      assert shot =~ "\nBROWSER canary=failed: No such file or directory"
      assert shot =~ ~r/\nwrite_system=failed: /
      assert shot =~ "\nwrite_checkout=ok"
      assert shot =~ "\nwrite_scratch=ok"
      refute shot =~ "patient record"

      # No host processes, and the environment is still built from nothing.
      assert shot =~ "\nhost_pid=hidden"
      assert shot =~ ~r/\nenv=[^\n]*\bPORT\b/
      refute shot =~ "ARB_CAPTURE_TEST_SECRET"
      refute shot =~ "hunter2"
    end

    # Nothing from either boot ever reached the coordinator, and nothing of the boot is left.
    assert {:error, :timeout} = :gen_tcp.accept(coordinator, 200)
    assert cap_dirs() -- cap_dirs_before == []
    :gen_tcp.close(coordinator)
  end

  # bd-3glf2a: a capture service as `Services.Podman` hands it over (a host Unix socket; here a
  # stand-in, `CaptureHostServices`, as CI has no podman), reached by setup and the app on
  # 127.0.0.1:<port> and at its declared socket path, and by nothing else.
  test "a declared service is reached on 127.0.0.1:<port> and its socket path, and by no other route",
       %{tmp_dir: dir} do
    {:ok, coordinator} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, coordinator_port} = :inet.port(coordinator)

    # Where a careless setup would publish the service on host loopback: reachable from the host
    # (the control below), never from inside.
    {published, published_port} = published_listener!()

    {control, 0} =
      System.cmd("perl", [
        Path.join(@fixtures, "probe_app.pl"),
        "--probe",
        "127.0.0.1",
        "#{published_port}"
      ])

    assert String.trim(control) == "connected"
    assert {:ok, peer} = :gen_tcp.accept(published, 2_000)
    :gen_tcp.close(peer)

    canary = Path.join(dir, "host-only.txt")
    File.write!(canary, "patient record")
    service_dirs = Path.join(Paths.socket_root(), "svct-#{System.unique_integer([:positive])}")

    db = %{
      name: "db",
      image: "unused-by-the-stand-in",
      port: 15_432,
      env: [],
      command: [],
      ready: %{kind: :tcp, timeout_seconds: 5},
      socket: "/run/probe/db.sock"
    }

    config =
      struct!(Config, %{
        ui_paths: ["routes.txt"],
        setup_cmd: "perl probe_app.pl --service 127.0.0.1 15432 > setup-service.txt",
        start_cmd: "exec perl probe_app.pl",
        port_range: {33_500, 33_600},
        services: [db],
        env: %{
          "PROBE_COORDINATOR_PORT" => Integer.to_string(coordinator_port),
          "PROBE_CANARY" => canary,
          "PROBE_HOST_PID" => System.pid(),
          "PROBE_SERVICE_PORT" => "15432",
          "PROBE_SERVICE_UNIX" => "/run/probe/db.sock",
          "PROBE_SERVICE_HOST_PORT" => Integer.to_string(published_port),
          "PROBE_SERVICE_DIR" => service_dirs <> "-{{role}}"
        },
        ready: %{"path" => "/", "timeout_seconds" => 30, "expect" => "below_500"}
      })

    plan = Path.join(dir, "screenshots.json")
    File.write!(plan, ~s({"version": 1, "shots": [{"id": "home", "path": "/"}]}))
    {repo, base, head} = repo!(dir)

    assert {:ok, %{pairs: [pair]}} =
             Capture.run(
               %{
                 task_id: "bd-services",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 config: config,
                 plan_path: plan,
                 out_dir: Path.join(dir, "out")
               },
               sandbox: Bwrap,
               services: CaptureHostServices,
               services_opts: [test_pid: self(), dir: service_dirs],
               ctx: %{chrome: browser!(dir, coordinator_port, canary, 15_432)}
             )

    for side <- [pair.before, pair.after] do
      shot = File.read!(side.file)
      JailProbe.evidence("capture services #{Path.basename(side.file)}", shot)
      assert shot =~ "HTTP/1.1 200 OK"

      # The declared endpoints lead to the service, for the setup command and the app.
      assert shot =~ "\nsetup_service=SERVICE db OK"
      assert shot =~ "\nservice=SERVICE db OK"
      assert shot =~ "\nservice_unix=SERVICE db OK"

      # Nothing else does: not the port it would have on host loopback, not the other sockets
      # beside it (only its own is shown in that directory), not the browser.
      assert shot =~ "\nservice_host_port=failed: Connection refused"
      assert shot =~ "\nservice_dir=db\n"
      refute shot =~ "other.sock"
      assert shot =~ "\nBROWSER service=failed: Connection refused"

      # And the sandbox is still the sandbox.
      assert shot =~ "\ncoordinator=failed: Connection refused"
      assert shot =~ "\nexternal_ip=failed: Network is unreachable"
      assert shot =~ "\ncanary=failed: No such file or directory"
      refute shot =~ "patient record"
    end

    # Each boot had its own services, and both were stopped.
    assert_received {:host_services, "before", before_dir}
    assert_received {:host_services, "after", after_dir}
    refute before_dir == after_dir
    assert_received {:host_services_stopped, ^before_dir}
    assert_received {:host_services_stopped, ^after_dir}
    refute File.exists?(before_dir)

    assert {:error, :timeout} = :gen_tcp.accept(published, 200)
    assert {:error, :timeout} = :gen_tcp.accept(coordinator, 200)
    :gen_tcp.close(published)
    :gen_tcp.close(coordinator)
  end

  # A host loopback port outside the app's port_range and the service's own.
  defp published_listener! do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(l)

    if port in 33_500..33_600 or port == 15_432 do
      :gen_tcp.close(l)
      published_listener!()
    else
      {l, port}
    end
  end

  # bd-3glf2a: the offline deps cache for real: seeded through the sandbox's network-on command
  # from the default branch's lockfile, then a boot compiles the head from it inside the sandbox,
  # which has no network at all.
  @tag timeout: 300_000
  test "a boot compiles from the offline deps cache, with no network", %{tmp_dir: dir} do
    toolchain = toolchain_dirs()
    dep = tiny_dep!(dir)
    {repo, base, head} = mix_app!(dir, dep)

    assert {:ok, cache} =
             DepsCache.prepare(
               %{
                 task_id: "bd-deps",
                 repo_path: repo,
                 base_sha: base,
                 head_sha: head,
                 default_branch: "main",
                 sandbox: Bwrap,
                 readonly_paths: toolchain ++ [dep],
                 timeout_s: 240
               },
               root: Path.join(dir, "cache-root")
             )

    checkout = Path.join(dir, "boot/checkout")
    scratch = Path.join(dir, "boot/scratch")
    File.mkdir_p!(checkout)
    File.mkdir_p!(Path.join(scratch, "home"))

    {_, 0} =
      System.cmd("sh", ["-c", "git -C '#{repo}' archive #{head} | tar -x -C '#{checkout}'"])

    box = %{
      checkout: checkout,
      scratch: scratch,
      readonly_paths: toolchain,
      cache_dirs: [cache.dir]
    }

    script = "mix run -e 'IO.puts(App.hi())' && echo routes=$(awk 'NR>1' /proc/net/route | wc -l)"
    {:ok, argv} = Bwrap.command(["sh", "-c", script], box, nil)

    env =
      [
        {"PATH", Sandbox.path()},
        {"HOME", Path.join(scratch, "home")},
        {"LANG", "C.UTF-8"},
        {"TMPDIR", scratch}
      ] ++ cache.env

    {:ok, pid} = AppProcess.start_link(%{argv: argv, cd: checkout, env: env})

    result =
      try do
        AppProcess.await_exit(pid, 240_000)
      after
        AppProcess.stop(pid)
      end

    assert {:exited, 0, out} = result, "the offline compile failed: #{inspect(result)}"
    JailProbe.evidence("capture deps cache compile", out)
    assert out =~ "from_the_cache"
    assert out =~ "routes=0"
    refute File.exists?(Path.join(checkout, "deps"))
  end

  # An app depending on `dep` (a local git repo: fetched with no network at all), its lockfile
  # committed on main as the default branch would have it; the head changes a UI path only.
  defp mix_app!(dir, dep) do
    repo = Path.join(dir, "app")
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(home)
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule App.MixProject do
      use Mix.Project
      def project, do: [app: :app, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
      defp deps, do: [{:tiny, git: "file://#{dep}", tag: "v1"}]
    end
    """)

    File.write!(
      Path.join(repo, "lib/app.ex"),
      "defmodule App do\n  def hi, do: Tiny.hello()\nend\n"
    )

    File.write!(Path.join(repo, "routes.txt"), "/")

    {out, status} =
      System.cmd("mix", ["deps.get"],
        cd: repo,
        env: [{"HOME", home}, {"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    File.rm_rf!(Path.join(repo, "deps"))
    File.rm_rf!(Path.join(repo, "_build"))
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(repo, "routes.txt"), "/\n/x")
    git!(repo, ["commit", "-q", "-am", "head"])
    {repo, base, git!(repo, ["rev-parse", "HEAD"])}
  end

  # The Elixir and Erlang this VM runs, wherever the host keeps them (CI: setup-beam's dirs).
  defp toolchain_dirs do
    exes =
      for name <- ~w(mix elixir erl),
          path = System.find_executable(name),
          do: Path.dirname(resolve(path))

    roots = [
      to_string(:code.root_dir()),
      Path.expand("../..", to_string(:code.lib_dir(:elixir)))
    ]

    Enum.uniq(exes ++ roots)
  end

  defp resolve(path, hops \\ 20)
  defp resolve(path, 0), do: path

  defp resolve(path, hops) do
    case File.read_link(path) do
      {:ok, target} -> resolve(Path.expand(target, Path.dirname(path)), hops - 1)
      {:error, _} -> path
    end
  end

  defp tiny_dep!(dir) do
    dep = Path.join(dir, "tiny_dep")
    File.mkdir_p!(Path.join(dep, "lib"))
    git!(dir, ["init", "-q", "-b", "main", dep])
    git!(dep, ["config", "user.email", "t@example.com"])
    git!(dep, ["config", "user.name", "t"])

    File.write!(Path.join(dep, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    File.write!(
      Path.join(dep, "lib/tiny.ex"),
      "defmodule Tiny do\n  def hello, do: :from_the_cache\nend\n"
    )

    git!(dep, ["add", "-A"])
    git!(dep, ["commit", "-q", "-m", "tiny"])
    git!(dep, ["tag", "v1"])
    dep
  end

  test "a probe of the sandbox on this host passes, so status/0 says :ok" do
    assert Bwrap.probe() == :ok
  end
end
