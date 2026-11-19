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

  Needs a working bwrap (skipped elsewhere, like the jail tests; CI's `jail` job sets
  `WARDMAST_TEST_REQUIRE_BWRAP=1`, which turns the skip into a failure).
  """

  use ExUnit.Case, async: false

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture
  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap
  alias Wardmast.Screenshots.Config
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
  defp browser!(dir, coordinator, canary) do
    bin = Path.join(dir, "browser")
    File.mkdir_p!(bin)
    chrome = Path.join(bin, "chrome")
    File.cp!(Path.join(@fixtures, "probe_chrome.pl"), chrome)
    File.chmod!(chrome, 0o755)
    File.write!(Path.join(bin, "coordinator_port"), Integer.to_string(coordinator))
    File.write!(Path.join(bin, "canary_path"), canary)
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

  test "a probe of the sandbox on this host passes, so status/0 says :ok" do
    assert Bwrap.probe() == :ok
  end
end
