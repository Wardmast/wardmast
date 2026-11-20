defmodule Wardmast.Screenshots.Capture.Sandbox.BwrapServicesScriptsTest do
  @moduledoc """
  The capture sandbox's service relays (bd-3glf2a), run for real with the bwrap step cut out of
  the argv, so they are tested on any Linux host with perl and socat: in front of an app command,
  one relay per service from `127.0.0.1:<port>` to the service's host socket, all listening before
  the command starts, and no command at all when one cannot. `capture_sandbox_test.exs` runs the
  same argv inside a real bwrap.
  """

  use ExUnit.Case, async: false

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap

  # The relays wait on /proc/net/tcp; the scripts need perl and socat.
  @moduletag :linux
  @moduletag :tmp_dir

  @missing Enum.reject(~w(perl socat sh), &System.find_executable/1)
  if @missing != [], do: @moduletag(skip: "needs #{Enum.join(@missing, ", ")} on PATH")

  @bwrap "/nonexistent/bwrap-is-cut-out"

  # What an app would do: connect to a service on loopback and keep the first line it sends.
  @client ~S"""
  use strict; use warnings; use Socket;
  my ($out, @ports) = @ARGV;
  open(my $o, '>>', $out) or die "write $out: $!\n";
  for my $port (@ports) {
    socket(my $s, PF_INET, SOCK_STREAM, 0) or die "socket: $!\n";
    connect($s, sockaddr_in($port, inet_aton('127.0.0.1'))) or die "connect $port: $!\n";
    my $line = <$s>;
    print $o $line;
    close $s;
  }
  close $o;
  """

  defp host do
    %{
      tools: %{
        bwrap: @bwrap,
        perl: System.find_executable("perl"),
        socat: System.find_executable("socat"),
        sh: System.find_executable("sh")
      },
      system: [],
      secret_files: [],
      mask_dirs: []
    }
  end

  defp unboxed(argv) do
    {outside, [@bwrap | rest]} = Enum.split_while(argv, &(&1 != @bwrap))
    outside ++ tl(Enum.drop_while(rest, &(&1 != "--")))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # A stand-in service: a host Unix socket (as the services layer makes one) that greets every
  # connection with its name.
  defp service!(dir, name) do
    path = Path.join(dir, name)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    pid = spawn(fn -> serve(listener, name) end)
    :ok = :gen_tcp.controlling_process(listener, pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    path
  end

  defp serve(listener, name) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :gen_tcp.send(conn, "svc:#{name}\n")
        :gen_tcp.close(conn)
        serve(listener, name)

      {:error, _} ->
        :ok
    end
  end

  setup do
    # Socket paths must stay under 108 bytes: a short dir of its own under the socket root.
    sockets =
      Path.join(Paths.socket_root(), "svct-#{System.unique_integer([:positive])}")

    File.mkdir_p!(sockets)
    on_exit(fn -> File.rm_rf(sockets) end)
    %{sockets: sockets}
  end

  defp run!(argv, dir) do
    proc =
      start_supervised!(
        {AppProcess, %{argv: unboxed(argv), cd: dir, env: [{"PATH", Sandbox.path()}]}},
        id: make_ref()
      )

    AppProcess.await_exit(proc, 20_000)
  end

  test "an app command reaches every service on 127.0.0.1:<port>, through its socket", %{
    tmp_dir: dir,
    sockets: sockets
  } do
    services = [
      %{name: "postgres", port: free_port(), socket: service!(sockets, "postgres")},
      %{name: "s3", port: free_port(), socket: service!(sockets, "s3")}
    ]

    out = Path.join(dir, "seen.txt")
    ports = Enum.map(services, &Integer.to_string(&1.port))
    perl = System.find_executable("perl")
    box = %{checkout: dir, scratch: dir, services: services}

    argv = Bwrap.command_argv([perl, "-e", @client, out | ports], box, nil, host())

    assert {:exited, 0, _tail} = run!(argv, dir)
    assert File.read!(out) == "svc:postgres\nsvc:s3\n"
  end

  test "a relay that cannot listen keeps the command from running at all (exit 125)", %{
    tmp_dir: dir,
    sockets: sockets
  } do
    # Something already holds the port (on every address, so the relay's own 127.0.0.1 bind
    # fails and nothing listening on 127.0.0.1 can be mistaken for it).
    {:ok, blocker} = :gen_tcp.listen(0, ip: {0, 0, 0, 0}, reuseaddr: false)
    {:ok, port} = :inet.port(blocker)
    on_exit(fn -> :gen_tcp.close(blocker) end)

    marker = Path.join(dir, "ran")
    services = [%{name: "postgres", port: port, socket: service!(sockets, "postgres")}]
    box = %{checkout: dir, scratch: dir, services: services}
    argv = Bwrap.command_argv(["/bin/sh", "-c", "touch #{marker}"], box, nil, host())

    assert {:exited, 125, tail} = run!(argv, dir)
    assert tail =~ "127.0.0.1:#{port}"
    refute File.exists?(marker)
  end
end
