defmodule Wardmast.Worker.TimeoutTest do
  use ExUnit.Case, async: true

  alias Wardmast.Worker.Timeout

  defp finder(map), do: fn name -> Map.get(map, name) end

  describe "resolve/1" do
    test "prefers timeout" do
      find = finder(%{"timeout" => "/bin/timeout", "gtimeout" => "/bin/gtimeout"})
      assert {:ok, "/bin/timeout"} = Timeout.resolve(find: find)
    end

    test "falls back to gtimeout" do
      assert {:ok, "/opt/gtimeout"} =
               Timeout.resolve(find: finder(%{"gtimeout" => "/opt/gtimeout"}))
    end

    test "returns :none when neither exists" do
      assert :none = Timeout.resolve(find: finder(%{}))
    end
  end

  describe "wrap/3 and shell_prefix/2" do
    test "wrap prefixes argv with the resolved binary" do
      find = finder(%{"gtimeout" => "/opt/gtimeout"})

      assert ["/opt/gtimeout", "--kill-after=2s", "7", "echo", "hi"] =
               Timeout.wrap(["echo", "hi"], 7, find: find, kill_after: 2)
    end

    test "wrap leaves argv alone with no binary" do
      assert ["echo"] = Timeout.wrap(["echo"], 7, find: finder(%{}))
    end

    test "shell_prefix names the binary or is empty" do
      assert "'/bin/timeout' -k 1 9 " =
               Timeout.shell_prefix(9, find: finder(%{"timeout" => "/bin/timeout"}))

      assert "" = Timeout.shell_prefix(9, find: finder(%{}))
    end
  end

  describe "cmd/4" do
    test "runs through the binary when available" do
      assert {out, 0} = Timeout.cmd("echo", ["hi"], 5, [])
      assert out =~ "hi"
    end

    test "Elixir-side bound runs the command when no binary exists" do
      assert {out, 0} = Timeout.cmd("echo", ["hi"], 5, find: finder(%{}))
      assert out =~ "hi"
    end

    test "Elixir-side bound returns 124 on expiry" do
      assert {"", 124} = Timeout.cmd("sleep", ["5"], 1, find: finder(%{}))
    end
  end
end
