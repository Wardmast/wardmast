defmodule WardmastCli.Scripts.MigrateFromArbiterTest do
  @moduledoc """
  `scripts/migrate-from-arbiter.sh` — the one-shot move of an existing
  `~/.arbiter` install to the `~/.wardmast` footprint (bd-4jzgwa).

  Every test runs the real script against a throwaway `$HOME`, with a stub
  `systemctl` first on `PATH` so nothing ever touches the operator's real user
  manager. The stub logs each call to `$HOME/systemctl.log` and answers
  `is-active` from `$HOME/active-units` (one unit name per line).
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/migrate-from-arbiter.sh", __DIR__)

  @old_env """
  # operator secrets
  SECRET_KEY_BASE=abc
  ARBITER_CLOAK_KEY=AAAA
  ARB_BIND_ADDRESS=0.0.0.0
  ARB_PRIMARY_CHECKOUT=%HOME%/dev/arbiter
  ARB_DATA_HOME=%HOME%/.arbiter
  DATABASE_PATH=%HOME%/.arbiter/arbiter.sqlite3
  ARB_TOKEN=keep-me
  ARBITER_MCP_TOKEN=keep-me-too
  ARB_NODE_HOME=%HOME%/.arbiter-node
  PATH=/usr/bin:%HOME%/.arbiter/bin
  """

  @old_unit """
  [Unit]
  Description=Arbiter stack
  [Service]
  Type=exec
  WorkingDirectory=%HOME%/.arbiter
  EnvironmentFile=-%HOME%/.arbiter/arbiter.env
  StandardOutput=append:%HOME%/.arbiter/log/arbiter.log
  ExecStart=%HOME%/.arbiter/current/bin/arbiter start
  [Install]
  WantedBy=default.target
  """

  setup do
    home = Path.join(System.tmp_dir!(), "migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    bin = Path.join(home, "stubbin")
    File.mkdir_p!(bin)
    stub = Path.join(bin, "systemctl")

    File.write!(stub, """
    #!/bin/sh
    echo "$*" >> "$HOME/systemctl.log"
    case "$*" in
      *is-active*)
        unit="$(printf '%s\\n' "$@" | tail -n 1)"
        grep -qx "$unit" "$HOME/active-units" 2>/dev/null
        exit $?
        ;;
    esac
    exit 0
    """)

    File.chmod!(stub, 0o755)
    {:ok, home: home}
  end

  defp run(home, args \\ []) do
    path = Path.join(home, "stubbin") <> ":" <> System.get_env("PATH")

    System.cmd("bash", [@script | args],
      env: [{"HOME", home}, {"PATH", path}, {"XDG_CONFIG_HOME", nil}],
      stderr_to_stdout: true
    )
  end

  defp sub(text, home), do: String.replace(text, "%HOME%", home)

  # A realistic pre-rename install: data home with a release + DB + env file +
  # log, a user unit with a drop-in and logrotate units, and the recorded
  # checkout path.
  defp legacy_install!(home) do
    old = Path.join(home, ".arbiter")
    File.mkdir_p!(Path.join(old, "releases/v1.2.3/bin"))
    File.mkdir_p!(Path.join(old, "snapshots"))
    File.mkdir_p!(Path.join(old, "log"))
    File.write!(Path.join(old, "arbiter.sqlite3"), "DB")
    File.write!(Path.join(old, "snapshots/arbiter-pre-v1-20260101T000000Z.sqlite3"), "SNAP")
    File.write!(Path.join(old, "log/arbiter.log"), "line\n")

    File.write!(
      Path.join(old, "log/logrotate.conf"),
      sub("\"%HOME%/.arbiter/log/arbiter.log\" {\n daily\n}\n", home)
    )

    env = Path.join(old, "arbiter.env")
    File.write!(env, sub(@old_env, home))
    File.chmod!(env, 0o600)
    File.ln_s!(Path.join(old, "releases/v1.2.3"), Path.join(old, "current"))

    units = Path.join(home, ".config/systemd/user")
    File.mkdir_p!(Path.join(units, "arbiter.service.d"))
    File.write!(Path.join(units, "arbiter.service"), sub(@old_unit, home))

    File.write!(
      Path.join(units, "arbiter.service.d/oom.conf"),
      "[Service]\nEnvironmentFile=-#{home}/.arbiter/arbiter.env\nOOMPolicy=continue\n"
    )

    File.write!(
      Path.join(units, "arbiter-logrotate.service"),
      sub("[Service]\nExecStart=logrotate %HOME%/.arbiter/log/logrotate.conf\n", home)
    )

    File.write!(Path.join(units, "arbiter-logrotate.timer"), "[Timer]\nOnCalendar=daily\n")

    File.mkdir_p!(Path.join(home, ".config/arbiter"))
    File.write!(Path.join(home, ".config/arbiter/home"), "#{home}/dev/arbiter\n")
    :ok
  end

  # path => contents for every regular file/symlink under `dir`, for no-op checks.
  defp tree(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.ends_with?(&1, "systemctl.log"))
    |> Map.new(fn p ->
      case File.read_link(p) do
        {:ok, target} -> {p, {:link, target}}
        _ -> {p, if(File.dir?(p), do: :dir, else: File.read!(p))}
      end
    end)
  end

  test "script exists and is executable" do
    assert %File.Stat{mode: mode} = File.stat!(@script)
    assert Bitwise.band(mode, 0o100) != 0
  end

  test "--help prints usage and exits 0", %{home: home} do
    {out, code} = run(home, ["--help"])
    assert code == 0
    assert out =~ "Usage: scripts/migrate-from-arbiter.sh"
  end

  describe "fresh run on a legacy install" do
    test "moves the data home, leaves a compat symlink, and keeps the DB intact", %{home: home} do
      legacy_install!(home)
      {out, code} = run(home)
      assert code == 0, out

      new = Path.join(home, ".wardmast")
      assert File.dir?(new)
      assert {:ok, ".wardmast"} = File.read_link(Path.join(home, ".arbiter"))
      assert File.read!(Path.join(new, "arbiter.sqlite3")) == "DB"
      assert File.exists?(Path.join(new, "snapshots/arbiter-pre-v1-20260101T000000Z.sqlite3"))
      assert File.read!(Path.join(new, "log/wardmast.log")) == "line\n"
      refute File.exists?(Path.join(new, "log/arbiter.log"))
    end

    test "repoints the absolute `current` symlink at the new home", %{home: home} do
      legacy_install!(home)
      {_, 0} = run(home)

      assert {:ok, target} = File.read_link(Path.join(home, ".wardmast/current"))
      assert target == Path.join(home, ".wardmast/releases/v1.2.3")
      assert File.dir?(target)
    end

    test "renames the env file, rewrites the keys, keeps 0600 and a backup", %{home: home} do
      legacy_install!(home)
      {_, 0} = run(home)

      env = Path.join(home, ".wardmast/wardmast.env")
      refute File.exists?(Path.join(home, ".wardmast/arbiter.env"))
      body = File.read!(env)

      assert body =~ "WARDMAST_CLOAK_KEY=AAAA\n"
      assert body =~ "WARDMAST_BIND_ADDRESS=0.0.0.0\n"
      assert body =~ "WARDMAST_PRIMARY_CHECKOUT=#{home}/dev/arbiter\n"
      assert body =~ "WARDMAST_DATA_HOME=#{home}/.wardmast\n"
      assert body =~ "DATABASE_PATH=#{home}/.wardmast/arbiter.sqlite3\n"
      assert body =~ "PATH=/usr/bin:#{home}/.wardmast/bin\n"
      refute body =~ "ARBITER_CLOAK_KEY"
      refute body =~ "ARB_BIND_ADDRESS"
      refute body =~ "ARB_PRIMARY_CHECKOUT"
      # Wire-contract / other-install variables are not ours to rename.
      assert body =~ "ARB_TOKEN=keep-me\n"
      assert body =~ "ARBITER_MCP_TOKEN=keep-me-too\n"
      assert body =~ "ARB_NODE_HOME=#{home}/.arbiter-node\n"
      assert body =~ "SECRET_KEY_BASE=abc\n"

      assert %File.Stat{mode: mode} = File.stat!(env)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert File.exists?(env <> ".pre-migrate")
    end

    test "installs wardmast.service (+ drop-in, logrotate) and disables the old unit", %{
      home: home
    } do
      legacy_install!(home)
      {out, code} = run(home)
      assert code == 0, out

      units = Path.join(home, ".config/systemd/user")
      unit = File.read!(Path.join(units, "wardmast.service"))
      assert unit =~ "ExecStart=#{home}/.wardmast/current/bin/wardmast start"
      assert unit =~ "EnvironmentFile=-#{home}/.wardmast/wardmast.env"
      assert unit =~ "StandardOutput=append:#{home}/.wardmast/log/wardmast.log"
      assert unit =~ "WorkingDirectory=#{home}/.wardmast\n"
      # (the scratch $HOME itself may contain "arbiter", so strip it first)
      stripped = String.replace(unit, home, "~")
      refute stripped =~ "arbiter"
      refute stripped =~ "Arbiter"

      dropin = File.read!(Path.join(units, "wardmast.service.d/oom.conf"))
      assert dropin =~ "EnvironmentFile=-#{home}/.wardmast/wardmast.env"
      assert dropin =~ "OOMPolicy=continue"

      assert File.exists?(Path.join(units, "wardmast-logrotate.timer"))
      assert File.read!(Path.join(units, "wardmast-logrotate.service")) =~ "#{home}/.wardmast/log/"
      assert File.read!(Path.join(home, ".wardmast/log/logrotate.conf")) =~ "wardmast.log"

      # The old unit and its drop-ins are gone from the unit search path.
      refute File.exists?(Path.join(units, "arbiter.service"))
      refute File.exists?(Path.join(units, "arbiter.service.d"))
      refute File.exists?(Path.join(units, "arbiter-logrotate.timer"))
      assert File.exists?(Path.join(units, "arbiter.service.pre-wardmast"))

      calls = File.read!(Path.join(home, "systemctl.log"))
      assert calls =~ "--user disable arbiter.service"
      assert calls =~ "--user daemon-reload"
      assert calls =~ "--user enable wardmast.service"
      # It prepares the unit; the operator starts it after reading the notes.
      refute calls =~ "start wardmast.service"
      refute calls =~ "restart"
      assert out =~ "systemctl --user start wardmast.service"
    end

    test "moves the recorded checkout path", %{home: home} do
      legacy_install!(home)
      {_, 0} = run(home)

      assert File.read!(Path.join(home, ".config/wardmast/home")) == "#{home}/dev/arbiter\n"
      refute File.exists?(Path.join(home, ".config/arbiter/home"))
    end

    test "--dry-run changes nothing", %{home: home} do
      legacy_install!(home)
      before = tree(home)
      {out, code} = run(home, ["--dry-run"])
      assert code == 0, out
      assert tree(home) == before
      assert out =~ "dry run"
    end
  end

  describe "re-run" do
    test "is a no-op once migrated", %{home: home} do
      legacy_install!(home)
      {_, 0} = run(home)
      after_first = tree(home)
      File.rm!(Path.join(home, "systemctl.log"))

      {out, code} = run(home)
      assert code == 0, out
      assert out =~ "already migrated"
      assert tree(home) == after_first

      # A no-op does not even poke systemd beyond the activity probe.
      calls = File.read!(Path.join(home, "systemctl.log"))
      refute calls =~ "disable"
      refute calls =~ "daemon-reload"
      refute calls =~ " enable "
    end

    test "on a machine with no Arbiter install is a clean no-op", %{home: home} do
      {out, code} = run(home)
      assert code == 0, out
      assert out =~ "nothing to migrate"
      refute File.exists?(Path.join(home, ".wardmast"))
      refute File.exists?(Path.join(home, ".config/systemd"))
    end

    test "finishes a half-done migration (data moved, unit not yet)", %{home: home} do
      legacy_install!(home)
      File.rename!(Path.join(home, ".arbiter"), Path.join(home, ".wardmast"))
      File.ln_s!(".wardmast", Path.join(home, ".arbiter"))

      {out, code} = run(home)
      assert code == 0, out
      assert File.exists?(Path.join(home, ".config/systemd/user/wardmast.service"))
      assert File.exists?(Path.join(home, ".wardmast/wardmast.env"))
    end
  end

  describe "refusals" do
    test "refuses while arbiter.service is active and changes nothing", %{home: home} do
      legacy_install!(home)
      File.write!(Path.join(home, "active-units"), "arbiter.service\n")
      before = tree(home)

      {out, code} = run(home)
      assert code != 0
      assert out =~ "arbiter.service is active"
      assert out =~ "systemctl --user stop"
      assert tree(home) == before
    end

    test "refuses while wardmast.service is active", %{home: home} do
      legacy_install!(home)
      File.write!(Path.join(home, "active-units"), "wardmast.service\n")
      before = tree(home)

      {out, code} = run(home)
      assert code != 0
      assert out =~ "wardmast.service is active"
      assert tree(home) == before
    end

    test "refuses when both ~/.arbiter and ~/.wardmast are real directories", %{home: home} do
      legacy_install!(home)
      File.mkdir_p!(Path.join(home, ".wardmast"))
      before = tree(home)

      {out, code} = run(home)
      assert code != 0
      assert out =~ "both"
      assert tree(home) == before
    end

    test "--dry-run still refuses while the service is active", %{home: home} do
      legacy_install!(home)
      File.write!(Path.join(home, "active-units"), "arbiter.service\n")
      {_, code} = run(home, ["--dry-run"])
      assert code != 0
    end

    test "rejects unknown arguments", %{home: home} do
      {out, code} = run(home, ["--bogus"])
      assert code == 2
      assert out =~ "Usage"
    end
  end

  test "documents the helm upgrade steps", %{home: home} do
    {out, code} = run(home, ["--helm-notes"])
    assert code == 0
    assert out =~ "helm upgrade"
    assert out =~ "wardmast-node"
  end

  test "every key the script rewrites is one the server reads under its new name" do
    script = File.read!(@script)
    [_, names] = Regex.run(~r/REWRITE_KEYS="([^"]+)"/, script)
    server_src = Path.expand("../../../..", __DIR__)

    sources =
      for dir <- ["apps/wardmast/lib", "apps/wardmast_cli/lib", "apps/wardmast_web/lib", "config"],
          file <- Path.wildcard(Path.join([server_src, dir, "**/*.{ex,exs,eex}"])),
          into: "",
          do: File.read!(file)

    for name <- String.split(names) do
      assert sources =~ "WARDMAST_#{name}", "WARDMAST_#{name} is not read anywhere"
    end
  end
end
