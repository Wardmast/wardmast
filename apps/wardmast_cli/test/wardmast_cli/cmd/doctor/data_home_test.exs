defmodule WardmastCli.Cmd.Doctor.DataHomeTest do
  @moduledoc """
  bd-dt5f6c: the doctor check that the CLI, the installed unit/plist and the
  running server agree on one data home. Every input is a fixture.
  """
  use ExUnit.Case, async: true

  alias WardmastCli.Cmd.Doctor.Checks.Result
  alias WardmastCli.Cmd.Doctor.DataHome

  @moduletag :tmp_dir

  defp plist!(dir, home) do
    pin =
      if home,
        do: """
            <key>EnvironmentVariables</key>
            <dict>
              <key>WARDMAST_DATA_HOME</key>
              <string>#{home}</string>
              <key>ARB_DATA_HOME</key>
              <string>#{home}</string>
            </dict>
        """,
        else: "<key>EnvironmentVariables</key><dict><key>HOME</key><string>/x</string></dict>"

    path = Path.join(dir, "dev.wardmast.plist")
    File.write!(path, "<plist><dict>#{pin}</dict></plist>")
    path
  end

  defp unit!(dir, home) do
    path = Path.join(dir, "wardmast.service")
    pin = if home, do: "Environment=WARDMAST_DATA_HOME=#{home}\n", else: ""
    File.write!(path, "[Service]\n#{pin}ExecStart=/x\n")
    path
  end

  defp server(home, extra \\ %{}) do
    Map.merge(
      %{
        "data_home" => home,
        "database_path" => Path.join(home, "arbiter.sqlite3"),
        "pid_file_path" => Path.join(home, "wardmast.pid")
      },
      extra
    )
  end

  defp run(opts), do: DataHome.check(Keyword.put_new(opts, :current_target, nil))

  test "CLI, plist, systemd unit and server all agree: green", %{tmp_dir: dir} do
    home = Path.join(dir, ".wardmast")

    for unit <- [plist!(dir, home), unit!(dir, home)] do
      assert %Result{status: :ok} =
               run(cli_home: home, unit_file: unit, server: server(home))
    end
  end

  test "the plist pins a different home than the CLI resolves: red, names both paths", %{
    tmp_dir: dir
  } do
    r = run(cli_home: "/cli/home", unit_file: plist!(dir, "/pinned/home"), server: nil)

    assert r.status == :fail
    assert r.detail =~ "/cli/home"
    assert r.detail =~ "/pinned/home"
    assert r.hint =~ "WARDMAST_DATA_HOME"
  end

  test "a legacy plist with no pin warns to re-run the installer", %{tmp_dir: dir} do
    r = run(cli_home: "/h", unit_file: plist!(dir, nil), server: nil)

    assert r.status == :warn
    assert r.hint =~ "arb install service"
  end

  test "a dev-mode unit with no pin is not legacy; server compared to the CLI", %{tmp_dir: dir} do
    path = Path.join(dir, "wardmast.service")

    File.write!(
      path,
      "[Unit]\nDescription=Wardmast [dev-mode source checkout]\n[Service]\nEnvironment=ARB_HOME=/x\nExecStart=/bin/sh /x/.run-server.sh\n"
    )

    assert %Result{status: :ok} = run(cli_home: "/h", unit_file: path, server: server("/h"))

    assert %Result{status: :fail} =
             run(cli_home: "/h", unit_file: path, server: server("/srv/other"))
  end

  test "the server reports a different home than the plist pins: red", %{tmp_dir: dir} do
    r = run(cli_home: "/h", unit_file: plist!(dir, "/h"), server: server("/srv/other"))

    assert r.status == :fail
    assert r.detail =~ "/srv/other"
    assert r.detail =~ "/h"
  end

  test "an explicit DATABASE_PATH outside the home is reported, not red", %{tmp_dir: dir} do
    home = Path.join(dir, ".wardmast")

    r =
      run(
        cli_home: home,
        unit_file: unit!(dir, home),
        server: server(home, %{"database_path" => "/elsewhere/db.sqlite3"})
      )

    assert r.status == :warn
    assert r.detail =~ "/elsewhere/db.sqlite3"
    assert r.detail =~ "DATABASE_PATH"
  end

  test "current pointing outside the data home is red", %{tmp_dir: dir} do
    home = Path.join(dir, ".wardmast")

    r =
      DataHome.check(
        cli_home: home,
        unit_file: unit!(dir, home),
        server: server(home),
        current_target: "/other/releases/1.0"
      )

    assert r.status == :fail
    assert r.detail =~ "/other/releases/1.0"
  end

  test "no installed unit and no reachable server: nothing to compare, green", %{tmp_dir: dir} do
    assert %Result{status: :ok} = run(cli_home: dir, unit_file: nil, server: nil)
  end
end
