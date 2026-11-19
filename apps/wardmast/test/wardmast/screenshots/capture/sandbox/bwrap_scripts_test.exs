defmodule Wardmast.Screenshots.Capture.Sandbox.BwrapScriptsTest do
  @moduledoc """
  The capture sandbox's own scripts (bd-bhrsdv), run for real with the bwrap step cut out of the
  argv, so they are tested on any Linux host: the host-side listener that creates the app's
  socket and hands it in as fd 3, the relay that forwards each connection to the app's port, and
  the browser's bridge from `127.0.0.1:<port>` to that socket. `capture_sandbox_test.exs` runs the
  same argv inside a real bwrap.
  """

  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Screenshots.Capture.Sandbox.Bwrap

  # The bridge waits on /proc/net/tcp; the scripts need perl and socat.
  @moduletag :linux
  @moduletag :tmp_dir

  @missing Enum.reject(~w(perl socat sh), &System.find_executable/1)
  if @missing != [], do: @moduletag(skip: "needs #{Enum.join(@missing, ", ")} on PATH")

  @fixtures Path.expand("../../../../fixtures/screenshots_app", __DIR__)
  @bwrap "/nonexistent/bwrap-is-cut-out"

  @fetch ~S"""
  use strict; use warnings; use Socket; use IO::Handle;
  my ($port, $out) = @ARGV;
  socket(my $s, PF_INET, SOCK_STREAM, 0) or die "socket: $!\n";
  connect($s, sockaddr_in($port, inet_aton('127.0.0.1'))) or die "connect: $!\n";
  $s->autoflush(1);
  print $s "GET / HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n";
  local $/;
  my $response = <$s>;
  open(my $o, '>', $out) or die "write $out: $!\n";
  print $o $response;
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

  # What runs inside the sandbox, run on the host instead: the argv with bwrap and its options
  # (up to and including the `--`) taken out.
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

  defp status(url, app) do
    Req.get(
      url,
      [retry: false, receive_timeout: 2_000, into: fn {:data, _}, acc -> {:halt, acc} end] ++
        Bwrap.reach(app)
    )
  end

  defp await_status(url, app, tries \\ 150) do
    case status(url, app) do
      {:ok, %{status: status}} ->
        status

      {:error, _} = error when tries == 0 ->
        error

      {:error, _} ->
        Process.sleep(100)
        await_status(url, app, tries - 1)
    end
  end

  setup %{tmp_dir: dir} do
    File.cp!(Path.join(@fixtures, "app.pl"), Path.join(dir, "app.pl"))
    File.write!(Path.join(dir, "routes.txt"), "/\n")
    port = free_port()
    box = %{checkout: dir, scratch: dir}

    assert {:ok, app} = Bwrap.expose(box, port)
    on_exit(fn -> Bwrap.release(app) end)

    # The app lists its own fds first: the relay must have closed the listener's fd 3 for it.
    command = "ls /proc/$$/fd > fds.txt; exec perl app.pl"
    argv = Bwrap.command_argv([System.find_executable("sh"), "-c", command], box, app, host())

    proc =
      start_supervised!(
        {AppProcess,
         %{argv: unboxed(argv), cd: dir, env: [{"PATH", Sandbox.path()}, {"PORT", "#{port}"}]}},
        id: :app
      )

    %{app: app, proc: proc, port: port, dir: dir}
  end

  test "the host's socket reaches the app's port through the relay", %{app: app, port: port} do
    assert await_status("http://127.0.0.1:#{port}/", app) == 200
    assert {:ok, %{status: 404}} = status("http://127.0.0.1:#{port}/missing", app)
  end

  test "the socket lives alone in a fresh 0700 directory, with a path short enough to bind", %{
    app: app,
    port: port
  } do
    assert await_status("http://127.0.0.1:#{port}/", app) == 200
    assert Path.dirname(app.socket) == app.dir
    assert Bitwise.band(File.stat!(app.dir).mode, 0o777) == 0o700
    assert byte_size(app.socket) <= 100
    assert File.ls!(app.dir) == ["s"]
  end

  test "the app itself never holds the listening socket", %{app: app, port: port, dir: dir} do
    assert await_status("http://127.0.0.1:#{port}/", app) == 200
    fds = dir |> Path.join("fds.txt") |> File.read!() |> String.split()
    assert "0" in fds
    refute "3" in fds
  end

  test "the browser's bridge is up before the browser runs, and leads to the app", %{
    app: app,
    port: port,
    dir: dir
  } do
    assert await_status("http://127.0.0.1:#{port}/", app) == 200

    # Inside the sandbox both sides use the same port number, in two namespaces; here, on one
    # host, the bridge needs a port of its own.
    bridge = free_port()
    shot = Path.join(dir, "shot")
    File.mkdir_p!(shot)
    page = Path.join(shot, "page")
    perl = System.find_executable("perl")

    argv =
      Bwrap.browser_argv(
        [perl, "-e", @fetch, "#{bridge}", page],
        %{app | port: bridge},
        [shot],
        host()
      )

    browser =
      start_supervised!(
        {AppProcess, %{argv: unboxed(argv), cd: shot, env: [{"PATH", Sandbox.path()}]}},
        id: :browser
      )

    assert {:exited, 0, _tail} = AppProcess.await_exit(browser, 15_000)
    assert File.read!(page) =~ "HTTP/1.1 200 OK"
  end

  test "release/1 removes the socket and its directory", %{app: app, port: port} do
    assert await_status("http://127.0.0.1:#{port}/", app) == 200
    assert File.exists?(app.socket)
    assert :ok = Bwrap.release(app)
    refute File.exists?(app.dir)
  end

  test "expose/2 refuses a socket path too long for a Unix socket", %{tmp_dir: dir} do
    if System.get_env("WARDMAST_SOCKET_ROOT") do
      # an operator override would win over the config this test sets
      :ok
    else
      saved = Application.fetch_env(:wardmast, :socket_root)
      Application.put_env(:wardmast, :socket_root, Path.join(dir, String.duplicate("d", 90)))

      on_exit(fn ->
        case saved do
          {:ok, v} -> Application.put_env(:wardmast, :socket_root, v)
          :error -> Application.delete_env(:wardmast, :socket_root)
        end
      end)

      assert {:error, {:socket_path_too_long, path} = reason} = Bwrap.expose(%{}, 4000)
      assert byte_size(path) > 100
      assert Bwrap.describe(reason) =~ "too long"
    end
  end
end
