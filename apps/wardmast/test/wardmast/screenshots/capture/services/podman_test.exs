defmodule Wardmast.Screenshots.Capture.Services.PodmanTest do
  @moduledoc """
  The capture services' lifecycle (bd-3glf2a) against a fake podman (`:runner`) and a fake
  bridge (`Wardmast.Test.CaptureFakeBridge`), so it runs anywhere: per-boot containers with no
  network, unique names, readiness, the log tail on failure, and removal on every exit path.
  `podman_capture_services_test.exs` runs the same against a real podman (opt-in).
  """

  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture.Services.Podman
  alias Wardmast.Screenshots.Capture.Services.Reaper
  alias Wardmast.Test.CaptureFakeBridge

  @pg %{
    name: "postgres",
    image: "docker.io/postgis/postgis:16-3.4",
    port: 5432,
    env: [{"POSTGRES_PASSWORD", "pw"}],
    command: ["postgres", "-c", "fsync=off"],
    ready: %{kind: :cmd, cmd: ["pg_isready", "-h", "127.0.0.1"], timeout_seconds: 5},
    socket: "/run/postgresql/.s.PGSQL.5432"
  }

  @s3 %{
    name: "s3",
    image: "docker.io/pgsty/silo",
    port: 9000,
    env: [],
    command: [],
    ready: %{kind: :tcp, timeout_seconds: 5},
    socket: nil
  }

  @log "LOG:  database system is starting up\nFATAL:  could not bind IPv4 address\n"

  # The fake podman: every call is reported to the test, answers come from `script`.
  defp runner(script \\ %{}) do
    test = self()

    fn cmd, args, _opts ->
      send(test, {:cmd, Path.basename(cmd), args})
      answer(Path.basename(cmd), args, script)
    end
  end

  defp answer("podman", ["run" | _], script), do: Map.get(script, :run, {"c0ffee\n", 0})
  defp answer("podman", ["inspect", "--format", "{{.State.Pid}}", _], _), do: {"4242\n", 0}

  defp answer("podman", ["inspect", "--format", "{{.State.Status}}", _], script),
    do: {Map.get(script, :status, "running") <> "\n", 0}

  defp answer("podman", ["exec" | _], script) do
    # `exec_ok_after`: the readiness command succeeds on that call (counted per test process).
    n = Process.get(:execs, 0) + 1
    Process.put(:execs, n)

    if n >= Map.get(script, :exec_ok_after, 1),
      do: {"accepting connections\n", 0},
      else: {"no response\n", 2}
  end

  defp answer("podman", ["logs" | _], _), do: {@log, 0}
  defp answer("podman", ["rm" | _], script), do: Map.get(script, :rm, {"", 0})
  defp answer("setpriv", _args, script), do: Map.get(script, :tcp, {"", 0})
  defp answer("nsenter", _args, script), do: Map.get(script, :tcp, {"", 0})

  # `timeout -k 5 <s> podman …`: answered as the podman call it wraps.
  defp answer("timeout", ["-k", _grace, _secs, podman | args], script),
    do: answer(Path.basename(podman), args, script)

  defp opts(script \\ %{}, extra \\ []) do
    Keyword.merge(
      [
        runner: runner(script),
        podman: "/usr/bin/podman",
        nsenter: "/usr/bin/nsenter",
        socat: "/usr/bin/socat",
        setpriv: "/usr/bin/setpriv",
        rootless: true,
        bridge: CaptureFakeBridge,
        bridge_opts: [test_pid: self()],
        ready_interval_ms: 0,
        reaper: false,
        timeout_bin: nil
      ],
      extra
    )
  end

  defp ctx(role, opts), do: %{role: role, task_id: "bd-test", opts: opts}

  defp seq?(list, seq), do: Enum.chunk_every(list, length(seq), 1, :discard) |> Enum.member?(seq)

  defp runs do
    {:messages, msgs} = Process.info(self(), :messages)
    for {:cmd, "podman", ["run", "-d", "--name", name | rest]} <- msgs, do: {name, rest}
  end

  defp removed do
    {:messages, msgs} = Process.info(self(), :messages)

    for {:cmd, "podman", ["rm", "--force", "--ignore", "--volumes", "--time", "0", name]} <- msgs,
        do: name
  end

  describe "start/2" do
    test "each service is a fresh container with no network, named for this boot" do
      assert {:ok, running} = Podman.start([@pg, @s3], ctx("before", opts()))
      on_exit(fn -> Podman.stop(running) end)

      assert [{pg_name, pg_args}, {s3_name, s3_args}] = runs()
      assert pg_name =~ ~r/\Aarb-cap-before-[0-9a-f]{8}-postgres\z/
      assert s3_name =~ ~r/\Aarb-cap-before-[0-9a-f]{8}-s3\z/

      for args <- [pg_args, s3_args] do
        assert seq?(args, ["--network", "none"])
        assert seq?(args, ["--security-opt", "no-new-privileges"])
        assert seq?(args, ["--cap-drop", "all"])
        # An image's VOLUME is RAM, gone with the container (no anonymous volume to leak).
        assert seq?(args, ["--image-volume", "tmpfs"])
        refute "--privileged" in args
        refute Enum.any?(args, &String.starts_with?(&1, "-v"))
        refute Enum.any?(args, &String.starts_with?(&1, "--volume"))
        refute Enum.any?(args, &String.starts_with?(&1, "-p"))
        refute Enum.any?(args, &String.starts_with?(&1, "--publish"))
        assert seq?(args, ["--label", "arbiter.capture-service=#{System.pid()}"])
        assert seq?(args, ["--label", "arbiter.capture-task=bd-test"])
        assert seq?(args, ["--label", "arbiter.capture-role=before"])
      end

      assert seq?(pg_args, ["-e", "POSTGRES_PASSWORD=pw"])

      assert Enum.drop_while(pg_args, &(&1 != "--")) ==
               ["--", @pg.image, "postgres", "-c", "fsync=off"]

      assert Enum.drop_while(s3_args, &(&1 != "--")) == ["--", @s3.image]
    end

    test "returns, per service, a host socket in a fresh 0700 dir and where the app reaches it" do
      assert {:ok, running} = Podman.start([@pg, @s3], ctx("before", opts()))
      on_exit(fn -> Podman.stop(running) end)

      assert [pg, s3] = running.endpoints
      assert %{name: "postgres", port: 5432, sandbox_socket: "/run/postgresql/.s.PGSQL.5432"} = pg
      assert %{name: "s3", port: 9000, sandbox_socket: nil} = s3

      dir = Path.dirname(pg.socket)
      assert Path.dirname(s3.socket) == dir
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
      assert byte_size(pg.socket) <= 100
      assert {:ok, %File.Stat{type: :other}} = File.lstat(pg.socket)
    end

    test "the bridge runs in the container's own network namespace, dying with the server" do
      assert {:ok, running} = Podman.start([@pg], ctx("before", opts()))
      on_exit(fn -> Podman.stop(running) end)
      [%{socket: socket}] = running.endpoints

      assert_received {:bridge_started, argv}

      assert argv == [
               "/usr/bin/setpriv",
               "--pdeathsig",
               "KILL",
               "--",
               "/usr/bin/nsenter",
               "--target",
               "4242",
               "--user",
               "--preserve-credentials",
               "--net",
               "--",
               "/usr/bin/socat",
               "UNIX-LISTEN:#{socket},fork,mode=0600",
               "TCP:127.0.0.1:5432"
             ]
    end

    test "as root (rootful podman) the bridge joins the network namespace only" do
      assert {:ok, running} = Podman.start([@pg], ctx("after", opts(%{}, rootless: false)))
      on_exit(fn -> Podman.stop(running) end)

      assert_received {:bridge_started, argv}
      refute "--user" in argv
      assert seq?(argv, ["--target", "4242", "--net", "--"])
    end

    test "the before and the after boot never share a container" do
      assert {:ok, before} = Podman.start([@pg], ctx("before", opts()))
      assert {:ok, after_boot} = Podman.start([@pg], ctx("after", opts()))
      on_exit(fn -> Enum.each([before, after_boot], &Podman.stop/1) end)

      assert [{before_name, _}, {after_name, _}] = runs()
      assert before_name =~ "arb-cap-before-"
      assert after_name =~ "arb-cap-after-"
      refute before_name == after_name
      refute hd(before.endpoints).socket == hd(after_boot.endpoints).socket

      # Two boots of the same role (a named seed) are as separate.
      assert {:ok, again} = Podman.start([@pg], ctx("before", opts()))
      on_exit(fn -> Podman.stop(again) end)
      names = Enum.map(runs(), &elem(&1, 0))
      assert length(Enum.uniq(names)) == 3
    end

    test "a cmd readiness check is exec'd in the container until it exits 0" do
      assert {:ok, running} = Podman.start([@pg], ctx("before", opts(%{exec_ok_after: 3})))
      on_exit(fn -> Podman.stop(running) end)

      {:messages, msgs} = Process.info(self(), :messages)
      execs = for {:cmd, "podman", ["exec", _name | cmd]} <- msgs, do: cmd
      assert execs == List.duplicate(["pg_isready", "-h", "127.0.0.1"], 3)
    end

    test "a tcp readiness check connects to the port inside the container's namespace" do
      assert {:ok, running} = Podman.start([@s3], ctx("before", opts()))
      on_exit(fn -> Podman.stop(running) end)

      {:messages, msgs} = Process.info(self(), :messages)

      assert [probe] =
               for(
                 {:cmd, "setpriv", args} <- msgs,
                 Enum.any?(args, &String.starts_with?(&1, "TCP:127.0.0.1:9000")),
                 do: args
               )

      assert seq?(probe, ["--target", "4242", "--user", "--preserve-credentials", "--net", "--"])
      assert seq?(probe, ["-u", "OPEN:/dev/null"])
    end
  end

  describe "start/2: bounded" do
    test "podman run is killed, not just abandoned, when it hangs (timeout -k)" do
      assert {:ok, running} =
               Podman.start([@pg], ctx("before", opts(%{}, timeout_bin: "/usr/bin/timeout")))

      on_exit(fn -> Podman.stop(running) end)

      assert_received {:cmd, "timeout", ["-k", "5", secs, "/usr/bin/podman", "run" | _]}
      assert String.to_integer(secs) in 1..300
    end

    test "the capture's budget caps the wait for a service" do
      slow = %{@pg | ready: %{@pg.ready | timeout_seconds: 60}}
      deadline = System.monotonic_time(:millisecond) + 600
      started = System.monotonic_time(:millisecond)

      context =
        Map.put(
          ctx("before", opts(%{exec_ok_after: 1_000_000}, ready_interval_ms: 50)),
          :deadline,
          deadline
        )

      assert {:error, failure} = Podman.start([slow], context)
      assert failure.reason =~ "budget"
      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end

  describe "start/2 failing: nothing is left behind" do
    test "a service that never gets ready is an error with its log tail" do
      short = %{@pg | ready: %{@pg.ready | timeout_seconds: 1}}

      assert {:error, failure} =
               Podman.start(
                 [@s3, short],
                 ctx("before", opts(%{exec_ok_after: 1_000_000}, ready_interval_ms: 50))
               )

      assert failure.service == "postgres"
      assert failure.reason =~ "did not become ready in 1 s"
      assert failure.log_tail =~ "FATAL:  could not bind IPv4 address"

      # Both containers (the ready one too) are removed, both bridges stopped, the dir gone.
      assert length(removed()) == 2
      assert MapSet.new(removed()) == MapSet.new(Enum.map(runs(), &elem(&1, 0)))
      assert_received {:bridge_stopped, _}
      assert_received {:bridge_stopped, _}
      assert_received {:bridge_started, argv}
      refute File.exists?(Path.dirname(CaptureFakeBridge.listen_path(argv)))
    end

    test "a container that exits before it is ready fails at once, with its log" do
      started = System.monotonic_time(:millisecond)

      assert {:error, failure} =
               Podman.start(
                 [@pg],
                 ctx("before", opts(%{exec_ok_after: 1_000_000, status: "exited"}))
               )

      assert failure.reason =~ "exited"
      assert failure.log_tail =~ "FATAL"
      assert System.monotonic_time(:millisecond) - started < 4_000
      assert [_] = removed()
    end

    test "podman run failing (an image it cannot get) names the image; the name is removed" do
      run = {"Error: docker.io/postgis/postgis:16-3.4: image not known\n", 125}

      assert {:error, failure} = Podman.start([@pg], ctx("before", opts(%{run: run})))
      assert failure.service == "postgres"
      assert failure.reason =~ "image not known"
      assert [_] = removed()
      refute_received {:bridge_started, _}
    end

    test "a bridge that cannot enter the namespace is an error with its output" do
      bridge_opts = [test_pid: self(), dies: "nsenter: reassociate to namespace failed"]

      assert {:error, failure} =
               Podman.start([@pg], ctx("before", opts(%{}, bridge_opts: bridge_opts)))

      assert failure.reason =~ "reassociate to namespace failed"
      assert [_] = removed()
    end

    test "no podman on this host is an error, and nothing is started" do
      assert {:error, failure} =
               Podman.start([@pg], ctx("before", opts(%{}, podman: nil, path: "/nonexistent")))

      assert failure.reason =~ "podman"
      assert runs() == []
    end
  end

  describe "stop/1" do
    test "removes every container by name, stops the bridges and removes the socket dir" do
      assert {:ok, running} = Podman.start([@pg, @s3], ctx("after", opts()))
      dir = running.endpoints |> hd() |> Map.fetch!(:socket) |> Path.dirname()

      assert :ok = Podman.stop(running)

      assert MapSet.new(removed()) == MapSet.new(Enum.map(runs(), &elem(&1, 0)))
      assert_received {:bridge_stopped, _}
      assert_received {:bridge_stopped, _}
      refute File.exists?(dir)
    end

    test "no services: nothing runs and stop is a no-op" do
      assert {:ok, %{endpoints: []} = running} = Podman.start([], ctx("before", opts()))
      assert :ok = Podman.stop(running)
      assert runs() == []
    end
  end

  describe "with the reaper" do
    setup do
      reaper = start_supervised!({Reaper, name: nil, enabled: false})
      %{reaper: reaper}
    end

    test "an owner killed mid-capture still has its containers removed", %{reaper: reaper} do
      test = self()
      opts = opts(%{}, reaper: reaper, runner: runner(), bridge_opts: [])

      owner =
        spawn(fn ->
          {:ok, running} = Podman.start([@pg, @s3], ctx("before", opts))
          send(test, {:started, running})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:started, _running}, 5_000
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      # The reaper handled the :DOWN before answering this call.
      _ = :sys.get_state(reaper)
      assert length(removed()) == 2
    end

    test "a server shutdown removes every container still running", %{reaper: reaper} do
      assert {:ok, _running} = Podman.start([@pg], ctx("before", opts(%{}, reaper: reaper)))
      assert removed() == []

      :ok = stop_supervised(Reaper)
      assert [_] = removed()
    end

    test "a container podman could not remove stays tracked, for the reaper to retry", %{
      reaper: reaper
    } do
      rm = {"Error: cannot remove container: device busy", 125}

      assert {:ok, running} =
               Podman.start([@pg], ctx("before", opts(%{rm: rm}, reaper: reaper)))

      [name] = Enum.map(running.handle.started, & &1.name)

      assert :ok = Podman.stop(running)
      assert [^name] = removed()

      items = :sys.get_state(reaper).owners |> Map.values() |> Enum.flat_map(& &1.items)
      assert Enum.any?(items, &match?({:container, ^name, _}, &1))
      # The socket directory itself is gone either way.
      refute Enum.any?(items, &match?({:dir, _}, &1))
    end

    test "a normal stop untracks: the owner's later exit removes nothing again", %{
      reaper: reaper
    } do
      assert {:ok, running} = Podman.start([@pg], ctx("before", opts(%{}, reaper: reaper)))
      assert :ok = Podman.stop(running)
      assert [_] = removed()
      assert :sys.get_state(reaper).owners == %{}
    end
  end

  describe "reap_orphans/1" do
    test "removes the containers a dead server left, never a live server's" do
      listing =
        Jason.encode!([
          %{
            "Names" => ["arb-cap-before-0001-postgres"],
            "Labels" => %{"arbiter.capture-service" => "111"}
          },
          %{
            "Names" => ["arb-cap-after-0002-postgres"],
            "Labels" => %{"arbiter.capture-service" => "222"}
          },
          %{"Names" => ["someone-elses"], "Labels" => %{"arbiter.capture-service" => "111"}}
        ])

      test = self()

      runner = fn cmd, args, _opts ->
        send(test, {:cmd, Path.basename(cmd), args})

        case args do
          ["ps" | _] -> {listing, 0}
          ["rm" | _] -> {"", 0}
        end
      end

      removed =
        Podman.reap_orphans(
          runner: runner,
          podman: "/usr/bin/podman",
          alive?: fn pid -> pid == "222" end
        )

      assert removed == ["arb-cap-before-0001-postgres"]

      assert_received {:cmd, "podman",
                       ["ps", "-a", "--filter", "label=arbiter.capture-service" | _]}

      assert [_] = removed()
    end
  end
end
