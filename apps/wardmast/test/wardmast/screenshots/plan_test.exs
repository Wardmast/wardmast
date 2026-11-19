defmodule Wardmast.Screenshots.PlanTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Config
  alias Wardmast.Screenshots.Plan

  @config %Config{}

  defp json(map), do: Jason.encode!(map)

  describe "parse/2" do
    test "expands a shot to one entry per viewport x theme, with config defaults" do
      body =
        json(%{
          "version" => 1,
          "shots" => [
            %{"id" => "home", "path" => "/", "viewports" => ["desktop", "mobile"]},
            %{"id" => "settings", "path" => "/settings?tab=a", "themes" => ["light", "dark"]}
          ]
        })

      assert {:ok, %Plan{skip: nil, shots: shots}} = Plan.parse(body, @config)

      assert [{"home", "desktop", "light"}, {"home", "mobile", "light"}] ==
               shots |> Enum.take(2) |> Enum.map(&{&1.id, &1.viewport, &1.theme})

      assert [{"settings", "desktop", "light"}, {"settings", "desktop", "dark"}] ==
               shots |> Enum.drop(2) |> Enum.map(&{&1.id, &1.viewport, &1.theme})
    end

    test "an entry carries path, before_path, title and steps" do
      body =
        json(%{
          "version" => 1,
          "shots" => [
            %{
              "id" => "edit",
              "title" => "Edit modal",
              "path" => "/p/1",
              "before_path" => "/patient/1",
              "steps" => [%{"action" => "click", "selector" => "#edit"}]
            }
          ]
        })

      assert {:ok, %Plan{shots: [entry]}} = Plan.parse(body, @config)
      assert entry.title == "Edit modal"
      assert entry.path == "/p/1"
      assert entry.before_path == "/patient/1"
      assert entry.steps == [%{"action" => "click", "selector" => "#edit"}]
    end

    test "a skip plan parses with no shots" do
      assert {:ok, %Plan{skip: "docs-only", shots: []}} =
               Plan.parse(json(%{"version" => 1, "skip" => "docs-only"}), @config)
    end

    test "invalid JSON is an invalid plan" do
      assert {:error, {:invalid, [msg]}} = Plan.parse("{nope", @config)
      assert msg =~ "JSON"
    end

    test "rejects bad versions, unknown keys, duplicate ids, hosts in paths, unknown viewports" do
      body =
        json(%{
          "version" => 2,
          "bogus" => true,
          "shots" => [
            %{"id" => "a", "path" => "http://evil.example/"},
            %{"id" => "a", "path" => "/ok", "viewports" => ["watch"]},
            %{"id" => "Bad Id", "path" => "/x"}
          ]
        })

      assert {:error, {:invalid, errors}} = Plan.parse(body, @config)
      joined = Enum.join(errors, "\n")
      assert joined =~ "version"
      assert joined =~ "bogus"
      assert joined =~ "duplicate"
      assert joined =~ "path"
      assert joined =~ "watch"
      assert joined =~ "Bad Id"
    end

    test "skip and shots are mutually exclusive, and one is required" do
      assert {:error, {:invalid, _}} =
               Plan.parse(json(%{"version" => 1, "skip" => "x", "shots" => []}), @config)

      assert {:error, {:invalid, _}} = Plan.parse(json(%{"version" => 1}), @config)
    end

    test "enforces the image budget (shots x viewports x themes x 2)" do
      cfg = %{@config | limits: Map.put(@config.limits, "max_images", 4)}

      body =
        json(%{
          "version" => 1,
          "shots" => [
            %{"id" => "a", "path" => "/", "viewports" => ["desktop", "mobile"]},
            %{"id" => "b", "path" => "/b"}
          ]
        })

      assert {:error, {:invalid, [msg]}} = Plan.parse(body, cfg)
      assert msg =~ "images"
    end

    test "rejects a step with a key its action does not take" do
      body =
        json(%{
          "version" => 1,
          "shots" => [
            %{
              "id" => "a",
              "path" => "/",
              "steps" => [%{"action" => "click", "selector" => "#a", "cmd" => "rm"}]
            }
          ]
        })

      assert {:error, {:invalid, [msg]}} = Plan.parse(body, @config)
      assert msg =~ "cmd"
    end
  end

  describe "read/2" do
    @tag :tmp_dir
    test "a missing file is :missing", %{tmp_dir: dir} do
      assert {:error, :missing} = Plan.read(Path.join(dir, "screenshots.json"), @config)
    end

    @tag :tmp_dir
    test "reads and parses a file", %{tmp_dir: dir} do
      path = Path.join(dir, "screenshots.json")
      File.write!(path, json(%{"version" => 1, "shots" => [%{"id" => "h", "path" => "/"}]}))
      assert {:ok, %Plan{shots: [%{id: "h"}]}} = Plan.read(path, @config)
    end
  end
end
