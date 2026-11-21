defmodule Wardmast.Doctor.CaptureRunnerTest do
  use ExUnit.Case, async: true

  alias Wardmast.Doctor.CaptureRunner

  @capture_dir Path.expand("../../../priv/capture", __DIR__)

  defp ws(screenshots) do
    %{config: %{"worker" => %{"repos" => %{"app" => %{"screenshots" => screenshots}}}}}
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "cr#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "the pinned playwright-core version comes from package-lock.json" do
    lock = @capture_dir |> Path.join("package-lock.json") |> File.read!() |> Jason.decode!()

    assert CaptureRunner.pinned_version(@capture_dir) ==
             lock["packages"]["node_modules/playwright-core"]["version"]

    assert is_binary(CaptureRunner.pinned_version(@capture_dir))
  end

  test "not enabled when no workspace turns screenshots on" do
    assert %{enabled: false} = CaptureRunner.report(workspaces: [%{config: %{}}])
  end

  test "enabled with a ready runner reports node, playwright-core and chromium" do
    dir = tmp_dir()
    File.mkdir_p!(Path.join(dir, "node_modules/playwright-core"))

    File.write!(
      Path.join(dir, "node_modules/playwright-core/package.json"),
      ~s({"version":"1.65.1"})
    )

    r =
      CaptureRunner.report(
        workspaces: [ws(%{"start_cmd" => "x", "enabled" => true})],
        capture_dir: dir,
        node_version: fn -> {:ok, "v22.3.0"} end,
        chrome: fn -> "/usr/bin/chromium" end,
        enabled?: fn _ -> true end
      )

    assert r.enabled
    assert r.node == "v22.3.0"
    assert r.playwright_core == "1.65.1"
    assert r.chromium == "/usr/bin/chromium"
    assert r.problems == []
  end

  test "enabled but nothing installed lists each problem" do
    r =
      CaptureRunner.report(
        workspaces: [ws(%{})],
        capture_dir: tmp_dir(),
        node_version: fn -> :error end,
        chrome: fn -> nil end,
        enabled?: fn _ -> true end
      )

    assert r.enabled
    assert length(r.problems) == 3
  end

  test "node older than 22 is a problem" do
    r =
      CaptureRunner.report(
        workspaces: [ws(%{})],
        capture_dir: tmp_dir(),
        node_version: fn -> {:ok, "v20.1.0"} end,
        chrome: fn -> "/c" end,
        enabled?: fn _ -> true end
      )

    assert Enum.any?(r.problems, &(&1 =~ "node"))
  end
end
