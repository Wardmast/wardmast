defmodule Wardmast.Screenshots.Capture.Services.PodmanCaptureServicesTest do
  @moduledoc """
  bd-3glf2a: `Services.Podman` against a REAL podman: a service container with no network,
  reached from the host only through the `nsenter`+`socat` bridge into its own namespace; fresh
  containers per boot; removal on stop, on a failed start, when the owner is killed and when the
  reaper shuts down.

  Opt-in (`@moduletag :podman`): it starts containers, and needs podman, nsenter, socat and a
  local `docker.io/library/debian:12` image (the service is a perl one-liner, perl-base is in it):

      cd apps/wardmast && mix test --include podman test/wardmast/screenshots/capture/services/podman_capture_services_test.exs

  Every container is named `arb-cap-…` and removed by that exact name: never a pattern kill (the
  coordinator runs on the same host).
  """

  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture.Services.Podman
  alias Wardmast.Screenshots.Capture.Services.Reaper

  @moduletag :podman
  @moduletag timeout: 300_000
  @image "docker.io/library/debian:12"

  # Greets every connection on 127.0.0.1:7070, inside the container.
  @server ~S"""
  use IO::Socket::INET;
  $| = 1;
  my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 7070, Listen => 5,
                                ReuseAddr => 1) or die "listen: $!\n";
  print "service listening\n";
  while (my $c = $s->accept) { print $c "SERVICE ok\n"; close $c }
  """

  defp service(extra \\ %{}) do
    Map.merge(
      %{
        name: "echo",
        image: @image,
        port: 7070,
        env: [{"SERVICE_FLAVOUR", "fixture"}],
        command: ["perl", "-e", @server],
        ready: %{kind: :tcp, timeout_seconds: 60},
        socket: nil
      },
      extra
    )
  end

  setup do
    {_, 0} = System.cmd("podman", ["image", "exists", @image])
    for tool <- ~w(nsenter socat), do: assert(System.find_executable(tool), "#{tool} missing")
    :ok
  end

  defp ctx(role, extra \\ []),
    do: %{role: role, task_id: "bd-podman-test", opts: Keyword.merge([reaper: false], extra)}

  defp names(running), do: Enum.map(running.handle.started, & &1.name)

  defp exists?(name),
    do: match?({_, 0}, System.cmd("podman", ["container", "exists", name]))

  defp greet(socket) do
    {:ok, conn} = :gen_tcp.connect({:local, socket}, 0, [:binary, active: false], 5_000)

    try do
      :gen_tcp.recv(conn, 0, 5_000)
    after
      :gen_tcp.close(conn)
    end
  end

  defp cleanup(names), do: on_exit(fn -> Enum.each(names, &Podman.remove(&1, [])) end)

  test "a service is reached through the host socket alone, and its container has no network" do
    assert {:ok, running} = Podman.start([service()], ctx("before"))
    cleanup(names(running))
    [name] = names(running)
    [%{socket: socket, port: 7070}] = running.endpoints

    assert {:ok, "SERVICE ok\n"} = greet(socket)

    # --network none: only its own lo, no route, nothing published.
    {mode, 0} = System.cmd("podman", ["inspect", "--format", "{{.HostConfig.NetworkMode}}", name])
    assert String.trim(mode) == "none"
    {dev, 0} = System.cmd("podman", ["exec", name, "cat", "/proc/net/dev"])

    interfaces =
      for line <- Enum.drop(String.split(dev, "\n", trim: true), 2),
          do: hd(String.split(line, ":")) |> String.trim()

    assert interfaces == ["lo"]
    {ports, 0} = System.cmd("podman", ["port", name])
    assert String.trim(ports) == ""

    assert :ok = Podman.stop(running)
    refute exists?(name)
    refute File.exists?(Path.dirname(socket))
  end

  test "the before and the after boot get containers of their own, both removed" do
    assert {:ok, before} = Podman.start([service()], ctx("before"))
    assert {:ok, after_boot} = Podman.start([service()], ctx("after"))
    cleanup(names(before) ++ names(after_boot))

    [b] = names(before)
    [a] = names(after_boot)
    refute a == b
    assert exists?(a) and exists?(b)

    :ok = Podman.stop(before)
    :ok = Podman.stop(after_boot)
    refute exists?(a)
    refute exists?(b)
  end

  test "a service that never gets ready: its log tail, and nothing left" do
    failing =
      service(%{
        command: ["sh", "-c", "echo booting; echo 'FATAL: the fixture refuses'; exec sleep 600"],
        ready: %{kind: :cmd, cmd: ["false"], timeout_seconds: 3}
      })

    assert {:error, failure} = Podman.start([failing], ctx("before"))
    assert failure.service == "echo"
    assert failure.reason =~ "did not become ready in 3 s"
    assert failure.log_tail =~ "FATAL: the fixture refuses"

    {listing, 0} =
      System.cmd("podman", [
        "ps",
        "-a",
        "--filter",
        "label=arbiter.capture-task=bd-podman-test",
        "--format",
        "{{.Names}}"
      ])

    assert String.trim(listing) == ""
  end

  test "the reaper removes a killed owner's containers, and every one at shutdown" do
    reaper = start_supervised!({Reaper, name: nil, enabled: false})
    test = self()

    owner =
      spawn(fn ->
        {:ok, running} = Podman.start([service()], ctx("before", reaper: reaper))
        send(test, {:started, names(running)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:started, [killed]}, 120_000
    cleanup([killed])
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    _ = :sys.get_state(reaper)
    refute exists?(killed)

    assert {:ok, running} = Podman.start([service()], ctx("after", reaper: reaper))
    [live] = names(running)
    cleanup([live])
    assert exists?(live)

    :ok = stop_supervised(Reaper)
    refute exists?(live)
  end
end
