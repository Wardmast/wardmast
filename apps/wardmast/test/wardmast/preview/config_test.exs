defmodule Wardmast.Preview.ConfigTest do
  use ExUnit.Case, async: true

  alias Wardmast.Preview.Config

  describe "validate/2" do
    test "accepts a full block" do
      block = %{
        "command" => "mix phx.server",
        "setup" => "mix deps.get",
        "port_env" => "PORT",
        "env" => %{"DATABASE_PATH" => "/tmp/preview-{{task_id}}.sqlite3", "X" => "{{checkout}}"},
        "ready_path" => "/health",
        "ready_timeout" => 90,
        "port_range" => "31000-31999",
        "idle_ttl_seconds" => 600
      }

      assert Config.validate(block, "worker.preview") == []
    end

    test "accepts a list port_range and an empty block" do
      assert Config.validate(%{"port_range" => [31_000, 31_010]}, "p") == []
      assert Config.validate(%{}, "p") == []
    end

    test "refuses unknown keys" do
      assert [msg] = Config.validate(%{"comand" => "x"}, "worker.preview")
      assert msg =~ "worker.preview has unknown key(s) comand"
    end

    test "refuses invalid values, naming the key" do
      for {block, expected} <- [
            {%{"command" => " "}, "p.command must be a non-empty string"},
            {%{"command" => 5}, "p.command must be a non-empty string"},
            {%{"setup" => ""}, "p.setup must be a non-empty string"},
            {%{"port_env" => "1BAD"}, "p.port_env must be an environment variable name"},
            {%{"env" => "A=B"}, "p.env must be a map of strings"},
            {%{"env" => %{"A" => 1}}, "p.env.A must be a string"},
            {%{"env" => %{"a-b" => "x"}}, "p.env key \"a-b\" is not a valid environment variable name"},
            {%{"ready_path" => "health"}, "p.ready_path must start with /"},
            {%{"ready_timeout" => 0}, "p.ready_timeout must be a positive integer"},
            {%{"ready_timeout" => 99_999}, "p.ready_timeout must be at most 3600"},
            {%{"idle_ttl_seconds" => -1}, "p.idle_ttl_seconds must be a positive integer"},
            {%{"port_range" => "abc"}, "p.port_range must be"},
            {%{"port_range" => "31999-31000"}, "p.port_range must be"},
            {%{"port_range" => "80-90"}, "p.port_range must lie within 1024-65535"},
            {%{"port_range" => "25000-31000"}, "overlaps the worker dev-server range 20000-29999"},
            {%{"command" => "run {{prot}}"}, "p.command uses unknown placeholder {{prot}}"},
            {%{"env" => %{"A" => "{{nope}}"}}, "p.env.A uses unknown placeholder {{nope}}"}
          ] do
        errors = Config.validate(block, "p")
        assert Enum.any?(errors, &(&1 =~ expected)), "#{inspect(block)} -> #{inspect(errors)}"
      end
    end

    test "refuses a non-map block" do
      assert [msg] = Config.validate("mix phx.server", "p")
      assert msg =~ "p must be a map"
    end
  end

  describe "resolve/2" do
    test "deep merges worker.preview with worker.repos.<repo>.preview and applies defaults" do
      ws = %{
        config: %{
          "worker" => %{
            "preview" => %{"ready_timeout" => 30, "env" => %{"A" => "1", "B" => "2"}},
            "repos" => %{
              "app" => %{"preview" => %{"command" => "bin/dev", "env" => %{"B" => "3"}}}
            }
          }
        }
      }

      assert {:ok, cfg} = Config.resolve(ws, "app")
      assert cfg.command == "bin/dev"
      assert cfg.setup == nil
      assert cfg.port_env == "PORT"
      assert cfg.env == %{"A" => "1", "B" => "3"}
      assert cfg.ready_path == "/"
      assert cfg.ready_timeout == 30
      assert cfg.port_range == {31_000, 31_999}
      assert cfg.idle_ttl_seconds == 7200
    end

    test "is :not_configured with no command, :error on an unreadable block" do
      assert {:error, :not_configured} = Config.resolve(%{config: %{}}, "app")
      assert {:error, :not_configured} = Config.resolve(nil, "app")

      ws = %{config: %{"worker" => %{"preview" => %{"command" => "x", "port_range" => "bad"}}}}
      assert {:error, {:invalid, _}} = Config.resolve(ws, "app")
    end
  end

  describe "render/2" do
    test "substitutes the known placeholders" do
      vars = %{port: 31_001, task_id: "bd-1", checkout: "/w/x", host: "127.0.0.1"}

      assert Config.render("run --port {{port}} {{task_id}} {{checkout}} {{host}}", vars) ==
               "run --port 31001 bd-1 /w/x 127.0.0.1"
    end
  end
end
