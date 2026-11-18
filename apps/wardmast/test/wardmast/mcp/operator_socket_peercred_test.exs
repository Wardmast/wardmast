defmodule Wardmast.MCP.OperatorSocketPeercredTest do
  @moduledoc """
  How `Wardmast.MCP.OperatorSocket` asks the kernel who connected
  (bd-5tg348): `SO_PEERCRED` on Linux, `LOCAL_PEERCRED` plus `LOCAL_PEERPID`
  on macOS.

  `peer_credentials/3` takes the `:inet.getopts/2` it calls, so the darwin
  read is checked on any host: which options it asks for, and how it decodes
  the replies. The real connection at the bottom is not tagged `:linux`. On
  Linux it goes through `SO_PEERCRED` and `/proc`; the macOS CI job runs it
  through `LOCAL_PEERCRED`, `LOCAL_PEERPID` and `ps`.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Wardmast.MCP.OperatorSocket

  # macOS sys/un.h: SOL_LOCAL 0, LOCAL_PEERCRED 1 (struct xucred, 76 bytes),
  # LOCAL_PEERPID 2 (an int). Linux: SOL_SOCKET 1, SO_PEERCRED 17 (struct ucred).
  @local_peercred {:raw, 0, 1, 76}
  @local_peerpid {:raw, 0, 2, 4}
  @so_peercred {:raw, 1, 17, 12}

  # struct xucred: version 0, uid 501, 3 groups (staff first), padded to 16.
  @xucred <<0::native-unsigned-32, 501::native-unsigned-32, 3::native-signed-16, 0::16,
            20::native-unsigned-32, 12::native-unsigned-32, 61::native-unsigned-32,
            0::size(13 * 32)>>

  # A stand-in for :inet.getopts/2 that records what it was asked for.
  defp kernel(replies) do
    test = self()

    fn :sock, [opt] ->
      send(test, {:getopts, opt})
      Map.get(replies, opt, {:error, :einval})
    end
  end

  defp raw_reply({:raw, level, name, _size}, bin), do: {:ok, [{:raw, level, name, bin}]}

  defp darwin_replies do
    %{
      @local_peercred => raw_reply(@local_peercred, @xucred),
      @local_peerpid => raw_reply(@local_peerpid, <<4242::native-signed-32>>)
    }
  end

  describe "on darwin" do
    test "reads LOCAL_PEERCRED for the uid and LOCAL_PEERPID for the pid, never SO_PEERCRED" do
      assert {:ok, %{pid: 4242, uid: 501, gid: 20}} =
               OperatorSocket.peer_credentials(:sock, :darwin, kernel(darwin_replies()))

      assert_received {:getopts, @local_peercred}
      assert_received {:getopts, @local_peerpid}
      refute_received {:getopts, @so_peercred}
    end

    test "a read the kernel refuses is :no_peercred" do
      for missing <- [@local_peercred, @local_peerpid] do
        replies = Map.put(darwin_replies(), missing, {:error, :enotconn})

        assert {:error, :no_peercred} =
                 OperatorSocket.peer_credentials(:sock, :darwin, kernel(replies))
      end
    end

    test "a payload that is not a version-0 xucred and an int is :no_peercred" do
      bad = [
        {@local_peercred, binary_part(@xucred, 0, 12)},
        {@local_peercred, <<1::native-unsigned-32>> <> binary_part(@xucred, 4, 72)},
        {@local_peerpid, <<4242::native-signed-16>>}
      ]

      for {opt, bin} <- bad do
        replies = Map.put(darwin_replies(), opt, raw_reply(opt, bin))

        assert {:error, :no_peercred} =
                 OperatorSocket.peer_credentials(:sock, :darwin, kernel(replies)),
               "accepted #{inspect(bin)} for #{inspect(opt)}"
      end
    end
  end

  describe "on linux" do
    test "reads SO_PEERCRED's struct ucred, and nothing at SOL_LOCAL" do
      ucred = <<42::native-signed-32, 1000::native-signed-32, 1001::native-signed-32>>
      replies = %{@so_peercred => raw_reply(@so_peercred, ucred)}

      assert {:ok, %{pid: 42, uid: 1000, gid: 1001}} =
               OperatorSocket.peer_credentials(:sock, :linux, kernel(replies))

      assert_received {:getopts, @so_peercred}
      refute_received {:getopts, {:raw, 0, _, _}}
    end
  end

  describe "a real connection (this VM is both the server and the client)" do
    setup do
      dir =
        Path.join(
          Wardmast.Config.Paths.socket_root(),
          "opc-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, path: Path.join(dir, "op.sock")}
    end

    # The kernel names this VM as the peer, so the policy refuses it as the
    # server itself. A host whose peer read failed would say no_peercred, and
    # one whose uid check failed would say foreign_uid.
    test "the kernel identifies the peer, and the policy refuses the server itself", %{
      path: path
    } do
      start_supervised!({OperatorSocket, path: path, authorize: [server_cgroup: nil], name: nil})

      {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
      :ok = :gen_tcp.send(sock, ~s({"op":"mint"}\n))
      {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)

      assert %{"error" => %{"reason" => "spawned_by_arbiter"}} = Jason.decode!(line)
    end
  end
end
