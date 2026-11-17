defmodule Wardmast.Sessions.NamingDarwinTest do
  @moduledoc """
  macOS runtime dir + pidfile naming (bd-a1pnnv, MAC P3-1).

  macOS has no `XDG_RUNTIME_DIR`, and `$TMPDIR` (`/var/folders/xx/…/T/`) is so
  long that `<TMPDIR>/arbiter/session-<uuid>.sock` overflows the 104-byte
  `sun_path` of a Unix socket — so the darwin socket dir is a short, private
  directory under `/tmp`.
  """
  use ExUnit.Case, async: false

  alias Wardmast.Sessions.Naming

  @id "0197a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

  setup do
    prior_os = Application.get_env(:wardmast, :sessions_os)
    prior_dir = Application.get_env(:wardmast, :sessions_runtime_dir)
    prior_xdg = System.get_env("XDG_RUNTIME_DIR")

    Application.delete_env(:wardmast, :sessions_runtime_dir)
    System.delete_env("XDG_RUNTIME_DIR")

    on_exit(fn ->
      restore(:sessions_os, prior_os)
      restore(:sessions_runtime_dir, prior_dir)
      if prior_xdg, do: System.put_env("XDG_RUNTIME_DIR", prior_xdg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:wardmast, key)
  defp restore(key, value), do: Application.put_env(:wardmast, key, value)

  describe "darwin runtime dir" do
    test "falls back to a short private dir under /tmp when XDG_RUNTIME_DIR is unset" do
      Application.put_env(:wardmast, :sessions_os, :darwin)

      assert {:ok, dir} = Naming.socket_dir()
      assert String.starts_with?(dir, "/tmp/arb-")
      assert {:ok, sock} = Naming.socket_path(@id)
      assert byte_size(sock) < 104
      assert Path.basename(sock) == "session-#{@id}.sock"
    end

    test "linux without XDG_RUNTIME_DIR is still :no_runtime_dir" do
      Application.put_env(:wardmast, :sessions_os, :linux)

      assert Naming.socket_dir() == {:error, :no_runtime_dir}
      assert Naming.socket_path(@id) == {:error, :no_runtime_dir}
    end

    test "an explicit runtime dir wins over the darwin fallback" do
      Application.put_env(:wardmast, :sessions_os, :darwin)
      Application.put_env(:wardmast, :sessions_runtime_dir, "/tmp/x")

      assert {:ok, "/tmp/x/arbiter"} = Naming.socket_dir()
    end

    test "refuses a socket path past the 104-byte darwin sun_path limit" do
      Application.put_env(:wardmast, :sessions_os, :darwin)
      long = "/tmp/" <> String.duplicate("a", 80)
      Application.put_env(:wardmast, :sessions_runtime_dir, long)

      assert {:error, {:socket_path_too_long, path, 103}} = Naming.socket_path(@id)
      assert byte_size(path) > 103
    end

    test "the same long path is accepted off darwin (108-byte sun_path is not enforced here)" do
      Application.put_env(:wardmast, :sessions_os, :linux)
      Application.put_env(:wardmast, :sessions_runtime_dir, "/tmp/" <> String.duplicate("a", 80))

      assert {:ok, _} = Naming.socket_path(@id)
    end
  end

  describe "ensure_socket_dir/0" do
    @tag :tmp_dir
    test "creates the darwin short dir and its parent private (0700)", %{tmp_dir: tmp} do
      Application.put_env(:wardmast, :sessions_os, :darwin)
      System.put_env("WARDMAST_SOCKET_ROOT", Path.join(tmp, "arb-root"))
      on_exit(fn -> System.delete_env("WARDMAST_SOCKET_ROOT") end)

      assert {:ok, dir} = Naming.ensure_socket_dir()
      assert dir == Path.join([tmp, "arb-root", "sessions"])

      for d <- [dir, Path.dirname(dir)] do
        assert Bitwise.band(File.stat!(d).mode, 0o077) == 0
      end
    end

    @tag :tmp_dir
    test "returns :no_runtime_dir when there is nowhere to put it" do
      Application.put_env(:wardmast, :sessions_os, :linux)
      assert Naming.ensure_socket_dir() == {:error, :no_runtime_dir}
    end
  end

  describe "pidfile" do
    setup do
      Application.put_env(:wardmast, :sessions_runtime_dir, "/tmp/pidtest")
      :ok
    end

    test "pid_path/1 sits beside the socket" do
      assert {:ok, "/tmp/pidtest/arbiter/session-#{@id}.pid"} == Naming.pid_path(@id)
    end

    test "session_id_from_pidfile/1 round-trips and rejects foreign names" do
      assert Naming.session_id_from_pidfile("/x/session-#{@id}.pid") == @id
      assert Naming.session_id_from_pidfile("/x/session-#{@id}.sock") == nil
      assert Naming.session_id_from_pidfile("/x/heartbeat-abc") == nil
      assert Naming.session_id_from_pidfile("/x/session-.pid") == nil
    end

    test "pid_glob/0 does not match sockets or pipe files" do
      assert {:ok, glob} = Naming.pid_glob()
      assert String.ends_with?(glob, "session-*.pid")
    end
  end
end
