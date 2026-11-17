System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")
System.delete_env("ARB_TOKEN")
System.delete_env("ARB_WORKSPACE")

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

ExUnit.start([exclude: [:escript_build] ++ linux_exclude] ++ max_cases_opts)

# Make sure :req's transitive apps (finch, mint, etc.) are started for tests
# that hit the Req.Test plug adapter.
{:ok, _} = Application.ensure_all_started(:req)
