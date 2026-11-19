defmodule Wardmast.NodeAgent.RunCodexHomeTest do
  @moduledoc """
  SI8 (`docs/design/remote-workers.md` §21.3.3): a Codex run's `CODEX_HOME` on a machine
  node. The spec's `config_dir` mount says `"tmpfs": true` and its files (the ChatGPT
  login, `config.toml`, `AGENTS.md`, `rules/arbiter.rules`) ride in `secret_files`; the
  agent writes them to a directory of its own on `$XDG_RUNTIME_DIR` and binds a disk
  directory over `<CODEX_HOME>/sessions`. The login, whose refresh token rotates, must
  never touch the node's disk, and the directory goes (recursively, following no link)
  only after the final transcript upload.
  """
  # async: false: the stub reads STUB_PODMAN_DIR from the process environment.
  use ExUnit.Case, async: false

  alias Wardmast.NodeAgent.{Checkout, Config, Exec, Run, Runs, Secrets, StubPodman}

  @auth ~s({"auth_mode":"chatgpt","tokens":{"refresh_token":"RT-SI8-LIVE-9d41"}})
  @home "/work/codex-home"

  setup do
    root = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}")
    stub_dir = Path.join(root, "stub")
    home = Path.join(root, "home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    podman = StubPodman.install(stub_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!({Task.Supervisor, name: Wardmast.NodeAgent.TaskSupervisor})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)

    config = %Config{
      node_home: home,
      credential: "arbn_x.y",
      primary_url: "http://127.0.0.1:1",
      node_id: "n1"
    }

    opts = [
      config: config,
      podman: podman,
      runtime_dir: rt,
      require_tmpfs: false,
      sink: self(),
      node_id: "n1",
      image_fun: fn _image, _opts -> :ok end,
      delegated_fun: fn -> ["memory", "pids", "cpu"] end,
      checkout_fun: &fake_checkout/3,
      exit_retention_ms: 60_000
    ]

    %{root: root, stub: stub_dir, home: home, rt: rt, opts: opts, config: config}
  end

  # Plays `Checkout.seed_from_primary/3`: a shadow with a git dir.
  defp fake_checkout(config, _co, shadow) do
    File.mkdir_p!(Path.join(shadow, ".git/info"))
    File.mkdir_p!(Checkout.store_objects(config))
    {:ok, %{known: []}}
  end

  defp codex_spec(run, overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run" => run,
        "task" => "bd-abc",
        "name" => "arb-#{run}",
        "install" => "inst1",
        "image" => %{
          "tag" => "localhost/arbiter-dev/beam:abc123",
          "ref" => "reg.example/r/worker@sha256:" <> String.duplicate("a", 64)
        },
        "cwd" => "/work/tree",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/work/tree"},
          %{"kind" => "home", "path" => "/work/home"},
          %{"kind" => "config_dir", "path" => @home, "tmpfs" => true},
          %{"kind" => "tmp", "path" => "/work/tmp"}
        ],
        "checkout" => %{"branch" => "feature/x", "read_only" => true},
        "env" => %{"CODEX_HOME" => @home},
        "secrets" => %{},
        "secret_files" => %{
          "codex-auth" => %{"content" => Base.encode64(@auth), "link" => "auth.json"},
          "codex-config" => %{
            "content" => Base.encode64("model = \"gpt\"\n"),
            "link" => "config.toml"
          },
          "codex-agents" => %{"content" => Base.encode64("memory"), "link" => "AGENTS.md"},
          "codex-rules" => %{
            "content" => Base.encode64("rules"),
            "link" => "rules/arbiter.rules"
          }
        },
        "command" => ["codex", "exec", "x"]
      },
      overrides
    )
  end

  defp wait_event(run, event) do
    assert_receive {:run_push, ^run, ^event, payload}, 5_000
    payload
  end

  defp argv(stub), do: File.read!(Path.join(stub, "run.argv")) |> String.split("\n", trim: true)

  defp tmpfs_info(root, rt) do
    path = Path.join(root, "mountinfo")

    File.write!(
      path,
      "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:30 / #{rt} rw - tmpfs tmpfs rw\n"
    )

    path
  end

  # Every regular file under `dir`, as one string: what a scan of persistent storage sees.
  defp scan(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&match?({:ok, %File.Stat{type: :regular}}, File.lstat(&1)))
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "the login lives only on the tmpfs, bound as CODEX_HOME, with sessions/ bound from disk",
       %{opts: opts, stub: stub, home: home, rt: rt, root: root} do
    opts =
      opts |> Keyword.put(:require_tmpfs, true) |> Keyword.put(:mountinfo, tmpfs_info(root, rt))

    StubPodman.write_mode(stub, "hang")

    assert {:ok, "c1"} = Runs.assign(codex_spec("c1"), opts)
    wait_event("c1", "run.ready")
    assert_receive {:run_push, "c1", "stdout", _}, 5_000

    codex_home = Secrets.config_home(rt, "c1")
    assert File.read!(Path.join(codex_home, "auth.json")) == @auth
    assert File.read!(Path.join(codex_home, "config.toml")) == "model = \"gpt\"\n"
    assert File.read!(Path.join(codex_home, "AGENTS.md")) == "memory"
    assert File.read!(Path.join(codex_home, "rules/arbiter.rules")) == "rules"
    assert Bitwise.band(File.stat!(Path.join(codex_home, "auth.json")).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(codex_home).mode, 0o777) == 0o700

    run_dir = Path.join([home, "runs", "c1"])
    sessions = Path.join([run_dir, "config", "sessions"])
    assert File.dir?(sessions)

    argv = argv(stub)
    assert Enum.any?(argv, &String.starts_with?(&1, "#{codex_home}:#{@home}:rw"))
    assert Enum.any?(argv, &String.starts_with?(&1, "#{sessions}:#{@home}/sessions:rw"))
    # the disk config dir itself is not what CODEX_HOME is
    refute Enum.any?(argv, &String.starts_with?(&1, "#{run_dir}/config:"))
    refute Enum.any?(argv, &String.contains?(&1, "RT-SI8-LIVE"))

    # nothing under the node's home (disk) or in what podman was handed holds the login
    refute scan(home) =~ "RT-SI8-LIVE"
    refute File.read!(Path.join(stub, "run.env")) =~ "RT-SI8-LIVE"
    refute File.read!(Path.join([stub, "graph", "config.json"])) =~ "RT-SI8-LIVE"
    refute StubPodman.recorded(stub) =~ "RT-SI8-LIVE"

    File.write!(Path.join(stub, "removed"), "")
    wait_event("c1", "exit")
    refute File.exists?(codex_home)
    refute File.exists?(Secrets.dir(rt, "c1"))
    refute scan(home) =~ "RT-SI8-LIVE"
  end

  test "the directory is removed after the final transcript upload, not before; only rollouts go up",
       %{opts: opts, stub: stub, home: home, rt: rt, config: config} do
    test = self()
    codex_home = Secrets.config_home(rt, "c2")

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:upload, File.exists?(Path.join(codex_home, "auth.json")), body})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    opts = Keyword.put(opts, :config, %{config | req_options: [plug: plug]})
    StubPodman.write_mode(stub, "hang")

    assert {:ok, "c2"} = Runs.assign(codex_spec("c2"), opts)
    wait_event("c2", "run.ready")
    assert_receive {:run_push, "c2", "stdout", _}, 5_000

    # what the CLI wrote while it ran: a rollout on disk, and a stray file beside it
    day = Path.join([home, "runs", "c2", "config", "sessions", "2026", "11", "19"])
    File.mkdir_p!(day)
    File.write!(Path.join(day, "rollout-2026-11-19T10-00-00-thread-1.jsonl"), ~s({"t":1}\n))
    File.write!(Path.join(day, "notes.txt"), "not a rollout")

    File.write!(Path.join(stub, "removed"), "")
    wait_event("c2", "exit")

    # the upload ran while the directory was still there; it is gone by the exit report
    assert_received {:upload, true, tar}
    refute File.exists?(codex_home)

    {:ok, names} = :erl_tar.table({:binary, tar}, [:compressed])
    names = Enum.map(names, &to_string/1)
    assert "sessions/2026/11/19/rollout-2026-11-19T10-00-00-thread-1.jsonl" in names
    refute Enum.any?(names, &String.contains?(&1, "notes.txt"))
    refute Enum.any?(names, &String.contains?(&1, "auth.json"))
  end

  test "the directory is gone after a cancel and after the process ends", %{
    opts: opts,
    stub: stub,
    rt: rt
  } do
    StubPodman.write_mode(stub, "hang")
    assert {:ok, "c3"} = Runs.assign(codex_spec("c3"), opts)
    wait_event("c3", "run.ready")
    assert_receive {:run_push, "c3", "stdout", _}, 5_000
    assert File.exists?(Path.join(Secrets.config_home(rt, "c3"), "auth.json"))

    assert :ok = Run.cancel("c3", "test")
    assert %{"cancelled" => true} = wait_event("c3", "exit")
    refute File.exists?(Secrets.config_home(rt, "c3"))

    assert :ok = Run.ack_exit("c3")
    refute File.exists?(Secrets.dir(rt, "c3"))
  end

  test "a quiesced run leaves no login on the tmpfs, only its rollouts on disk", %{
    opts: opts,
    stub: stub,
    rt: rt,
    home: home
  } do
    StubPodman.write_mode(stub, "hang")
    assert {:ok, "c4"} = Runs.assign(codex_spec("c4"), opts)
    wait_event("c4", "run.ready")
    assert_receive {:run_push, "c4", "stdout", _}, 5_000

    assert :ok = Run.quiesce("c4")
    wait_event("c4", "retained")
    refute File.exists?(Secrets.config_home(rt, "c4"))
    refute scan(home) =~ "RT-SI8-LIVE"
  end

  test "with no tmpfs runtime dir the run is refused, nothing is written and no container starts",
       %{opts: opts, root: root, rt: rt, stub: stub, home: home} do
    on_disk = Path.join(root, "mountinfo-disk")
    File.write!(on_disk, "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n")
    opts = opts |> Keyword.put(:require_tmpfs, true) |> Keyword.put(:mountinfo, on_disk)

    assert {:ok, "c5"} = Runs.assign(codex_spec("c5"), opts)
    assert %{"reason" => "unschedulable", "detail" => detail} = wait_event("c5", "run.refused")
    assert detail =~ "secrets_not_on_tmpfs"
    refute detail =~ "RT-SI8-LIVE"
    refute File.exists?(Path.join(rt, "arbiter-node"))
    refute File.exists?(Path.join(stub, "run.argv"))
    refute scan(home) =~ "RT-SI8-LIVE"
  end

  test "a spec with secret_files and no tmpfs config_dir is still refused", %{opts: opts} do
    mounts = [
      %{"kind" => "worktree", "path" => "/work/tree"},
      %{"kind" => "config_dir", "path" => @home}
    ]

    assert {:error, {:refused, _}} = Runs.assign(codex_spec("c6", %{"mounts" => mounts}), opts)
  end

  test "NodeAgent.Exec's gate container gets an empty placeholder where the tmpfs home was",
       %{opts: opts, stub: stub, rt: rt, home: home} do
    assert {:ok, "c7"} = Runs.assign(codex_spec("c7"), opts)
    wait_event("c7", "exit")
    assert :ok = Run.ack_exit("c7")
    wait_until(fn -> "c7" not in Runs.run_ids() end)

    codex_home = Secrets.config_home(rt, "c7")
    refute File.exists?(codex_home)

    assert {_, 0} = Exec.run("c7", "true", 30, opts)
    argv = argv(stub)

    # CODEX_HOME is still mounted, from an empty directory that is not the tmpfs one
    mount = Enum.find(argv, &String.ends_with?(&1, ":#{@home}:rw"))
    assert mount
    source = mount |> String.split(":") |> hd()
    refute String.starts_with?(source, rt)
    assert File.dir?(source)
    assert File.ls!(source) == []
    assert String.starts_with?(source, home)
    refute Enum.any?(argv, &String.contains?(&1, "RT-SI8-LIVE"))
    # and the tmpfs home was not re-made for it
    refute File.exists?(codex_home)
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        wait_until(fun, deadline)
    end
  end
end
