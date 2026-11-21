defmodule Wardmast.Screenshots.Capture.Shooter.ChromiumFindTest do
  use ExUnit.Case, async: true

  alias Wardmast.Screenshots.Capture.Shooter.Chromium

  defp finder(present), do: fn name -> if name in present, do: "/usr/bin/" <> name end

  test "finds chromium-browser when it is the only candidate on PATH" do
    assert Chromium.find_chrome(fn _ -> nil end, finder(["chromium-browser"]), fn _ -> true end) ==
             "/usr/bin/chromium-browser"
  end

  test "tries candidates in order" do
    both = finder(["google-chrome", "chromium-browser"])

    assert Chromium.find_chrome(fn _ -> nil end, both, fn _ -> true end) ==
             "/usr/bin/chromium-browser"
  end

  test "ARB_CHROME wins" do
    env = fn "ARB_CHROME" -> "/opt/c" end
    assert Chromium.find_chrome(env, finder(["chromium"]), fn _ -> true end) == "/opt/c"
  end

  test "nil when nothing is found" do
    assert Chromium.find_chrome(fn _ -> nil end, finder([]), fn _ -> false end) == nil
  end

  test "chrome/1 uses the candidate list" do
    spec = %{ctx: %{chrome: "/definitely/missing"}}
    assert {:error, {:shot, _}} = Chromium.chrome(spec)
  end
end
