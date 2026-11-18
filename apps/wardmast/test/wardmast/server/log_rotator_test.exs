defmodule Wardmast.Server.LogRotatorTest do
  use ExUnit.Case, async: true

  alias Wardmast.Server.LogRotator

  setup do
    dir = Path.join(System.tmp_dir!(), "lr#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "wardmast.log")}
  end

  test "under the cap or absent: no-op", %{path: path} do
    assert LogRotator.rotate(path, max_bytes: 10) == :ok
    File.write!(path, "tiny")
    assert LogRotator.rotate(path, max_bytes: 10) == :ok
    refute File.exists?(path <> ".1")
  end

  test "rotates at the cap while an O_APPEND writer fd stays open", %{path: path} do
    {:ok, fd} = File.open(path, [:append, :raw])
    :ok = :file.write(fd, String.duplicate("a", 100))

    assert LogRotator.rotate(path, max_bytes: 100, keep: 3) == :rotated
    assert File.read!(path <> ".1") == String.duplicate("a", 100)
    assert File.read!(path) == ""

    # The pre-existing fd still writes into the live file, at the new end.
    :ok = :file.write(fd, "after\n")
    assert File.read!(path) == "after\n"
    :ok = :file.close(fd)
  end

  test "shifts older generations and drops past :keep", %{path: path} do
    {:ok, fd} = File.open(path, [:append, :raw])

    for gen <- ["one", "two", "three"] do
      :ok = :file.write(fd, gen)
      assert LogRotator.rotate(path, max_bytes: 1, keep: 2) == :rotated
    end

    assert File.read!(path <> ".1") == "three"
    assert File.read!(path <> ".2") == "two"
    refute File.exists?(path <> ".3")
    :ok = :file.close(fd)
  end

  test "the GenServer rotates on its tick", %{path: path} do
    File.write!(path, String.duplicate("x", 50))

    pid =
      start_supervised!(
        {LogRotator, name: nil_name(), path: path, max_bytes: 10, interval_ms: 10, enabled: true}
      )

    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, _, _, _}, 200
    assert File.exists?(path <> ".1")
  end

  defp nil_name, do: :"lr_#{System.unique_integer([:positive])}"
end
