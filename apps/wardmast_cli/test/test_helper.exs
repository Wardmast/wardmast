# bd-datu4q: macOS host tuning (TMPDIR realpath, wider assert_receive_timeout). Must
# run before anything calls System.tmp_dir!/0. A no-op on Linux; see the script.
host_tuning =
  "../../../scripts/test_host_tuning.exs"
  |> Path.expand(__DIR__)
  |> Code.eval_file()
  |> elem(0)

host_tuning.normalize_tmpdir.(System.get_env(), :os.type())

System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")
System.delete_env("ARB_TOKEN")
System.delete_env("WARDMAST_WORKSPACE")
System.delete_env("ARB_WORKSPACE")
System.delete_env("ARBITER_WORKSPACE")
System.delete_env("WARDMAST_HOST")
System.delete_env("ARB_HOST")
System.delete_env("ARBITER_HOST")

# Never let a test exec `mix`, `systemctl`, `lsof` or `kill` for real through
# `WardmastCli.Cmd.Start.run_cmd/3`: an unstubbed restart test once killed the
# live coordinator's server from a worker (bd-asawcq).
Application.put_env(:wardmast_cli, :forbid_real_cmds, true)

# bd-90vo7y: ARB_TEST_MAX_CASES / worker-default cap on async cases.
max_cases_opts =
  "../../../scripts/test_max_cases.exs"
  |> Path.expand(__DIR__)
  |> Code.eval_file()
  |> elem(0)
  |> then(& &1.(System.get_env()))

# bd-cblu5p: `:linux` tests need a Linux-only facility (/proc, GNU `timeout`,
# `setsid`, a real bwrap/systemd, ELF tooling). They are excluded on darwin (the
# macOS CI smoke job) and wherever WARDMAST_TEST_EXCLUDE_LINUX=1 is set.
linux_exclude =
  "../../../scripts/test_exclude_linux.exs"
  |> Path.expand(__DIR__)
  |> Code.eval_file()
  |> elem(0)
  |> then(& &1.(System.get_env(), :os.type()))

ExUnit.start(
  [exclude: [:escript_build] ++ linux_exclude] ++
    host_tuning.ex_unit_opts.(System.get_env(), :os.type()) ++ max_cases_opts
)

# Make sure :req's transitive apps (finch, mint, etc.) are started for tests
# that hit the Req.Test plug adapter.
{:ok, _} = Application.ensure_all_started(:req)
