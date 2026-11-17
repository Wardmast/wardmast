defmodule WardmastCli.SessionSocketsTest do
  @moduledoc """
  Where the macOS tmux sockets / pidfiles live, found without the server
  (bd-a1pnnv, MAC P3-1). Mirrors `Wardmast.Sessions.Naming`'s darwin dir —
  `<socket_root>/sessions` — which this escript cannot call.
  """
  use ExUnit.Case, async: false

  alias WardmastCli.SessionSockets

  setup do
    root = Path.join(System.tmp_dir!(), "arb-sock-#{System.unique_integer([:positive])}")
    prior = System.get_env("WARDMAST_SOCKET_ROOT")
    System.put_env("WARDMAST_SOCKET_ROOT", root)

    on_exit(fn ->
      if prior,
        do: System.put_env("WARDMAST_SOCKET_ROOT", prior),
        else: System.delete_env("WARDMAST_SOCKET_ROOT")

      File.rm_rf(root)
    end)

    dir = Path.join(root, "sessions")
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  test "dirs/0 puts WARDMAST_SOCKET_ROOT/sessions first", %{dir: dir} do
    assert hd(SessionSockets.dirs()) == dir
  end

  test "find_socket/1 returns an existing socket and :error otherwise", %{dir: dir} do
    assert SessionSockets.find_socket("abc") == :error
    sock = Path.join(dir, "session-abc.sock")
    File.write!(sock, "")
    assert SessionSockets.find_socket("abc") == {:ok, sock}
  end

  test "pidfiles/0 lists {id, pid} for well-formed pidfiles only", %{dir: dir} do
    File.write!(Path.join(dir, "session-abc.pid"), "4242\n/x/session-abc.sock\n")
    File.write!(Path.join(dir, "session-bad.pid"), "garbage\n")
    File.write!(Path.join(dir, "session-abc.sock"), "")

    assert SessionSockets.pidfiles() == [{"abc", 4242}]
  end
end
