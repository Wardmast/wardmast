defmodule Wardmast.Support.BundleTest do
  use ExUnit.Case, async: false

  alias Wardmast.Support.Bundle

  @secrets [
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
    "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "AKIAABCDEFGHIJKLMNOP",
    "xoxb-1234567890-abcdefghij",
    "Bearer abcdefghijklmnopqrstuvwxyz012345",
    "hunter2-super-secret-value"
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "wardmast.log")

    File.write!(
      log,
      "line one\nleaked #{Enum.at(@secrets, 0)} and #{Enum.at(@secrets, 1)}\n" <>
        "aws #{Enum.at(@secrets, 2)} slack #{Enum.at(@secrets, 3)} #{Enum.at(@secrets, 4)}\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, log: log}
  end

  test "bundle has version, doctor, config and logs, with secrets redacted", %{log: log} do
    config = [
      secret_key_base: "hunter2-super-secret-value",
      nested: [api_token: "hunter2-super-secret-value", note: Enum.at(@secrets, 1)],
      port: 4848
    ]

    assert {:ok, %{filename: filename, data: data}} = Bundle.build(log_path: log, config: config)
    assert filename =~ ~r/^arb-support-bundle-.*\.tar\.gz$/

    {:ok, files} = :erl_tar.extract({:binary, data}, [:memory, :compressed])
    names = Enum.map(files, fn {n, _} -> to_string(n) end)
    for n <- ~w(version.txt doctor.txt config.txt logs/wardmast.log), do: assert(n in names)

    all = files |> Enum.map(fn {_, c} -> c end) |> Enum.join("\n")
    for s <- @secrets, do: refute(all =~ s, "leaked #{s}")
    assert all =~ "[REDACTED]"
    assert all =~ "4848"
    assert all =~ "line one"
  end

  test "missing log file does not break the bundle" do
    assert {:ok, %{data: data}} = Bundle.build(log_path: "/nonexistent/x.log", config: [])
    {:ok, files} = :erl_tar.extract({:binary, data}, [:memory, :compressed])
    assert Enum.any?(files, fn {n, _} -> to_string(n) == "version.txt" end)
  end
end
