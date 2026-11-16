defmodule WardmastWeb.ApplicationTest do
  use ExUnit.Case, async: true

  alias Wardmast.MCP.{OperatorProof, OperatorSocket}

  describe "operator_socket_children/1 (bd-8381tk)" do
    test "a serving endpoint gets the operator socket, keyed by its HTTP port" do
      assert [{OperatorSocket, opts}] =
               WardmastWeb.Application.operator_socket_children(serve?: true, port: 4848)

      assert opts[:path] == OperatorProof.socket_path(4848)
    end

    test "no socket when the endpoint does not serve (tests, `mix run`)" do
      assert [] = WardmastWeb.Application.operator_socket_children(serve?: false, port: 4848)
    end

    test "the operator can switch it off" do
      assert [] =
               WardmastWeb.Application.operator_socket_children(
                 serve?: true,
                 port: 4848,
                 enabled?: false
               )
    end
  end
end
