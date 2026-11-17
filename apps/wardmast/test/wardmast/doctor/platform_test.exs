defmodule Wardmast.Doctor.PlatformTest do
  use ExUnit.Case, async: true

  alias Wardmast.Doctor.Platform

  test "darwin: baseline dirs are appended to the PATH and tools resolve on it" do
    test_pid = self()

    find = fn name, path ->
      send(test_pid, {:find, name, path})
      if name == "gh", do: "/opt/homebrew/bin/gh"
    end

    report = Platform.report(os: {:unix, :darwin}, home: "/Users/x", path: "/usr/bin", find: find)

    assert report.os == "darwin"
    assert report.path == "/usr/bin:/opt/homebrew/bin:/usr/local/bin:/Users/x/.local/bin"
    assert report.tools["gh"] == "/opt/homebrew/bin/gh"
    assert report.tools["claude"] == nil
    expected = report.path
    assert_received {:find, "gtimeout", ^expected}
  end

  test "linux: the PATH is unchanged" do
    report = Platform.report(os: {:unix, :linux}, path: "/usr/bin", find: fn _, _ -> nil end)
    assert report == %{os: "linux", path: "/usr/bin", tools: Map.new(~w(gtimeout claude gh glab mise), &{&1, nil})}
  end
end
