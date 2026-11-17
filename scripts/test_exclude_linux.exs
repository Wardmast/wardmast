# Shared by the wardmast, wardmast_web and wardmast_cli test helpers (bd-cblu5p),
# via
#
#     Code.eval_file(Path.expand("../../../scripts/test_exclude_linux.exs", __DIR__))
#     |> elem(0) |> then(& &1.(System.get_env(), :os.type()))
#
# Evaluates to a 2-arity function, (env map, os_type) -> list of ExUnit tags to
# exclude. Tests that need a Linux-only facility (`/proc`, GNU `timeout`,
# `setsid`, a real bwrap/systemd, ELF tooling) carry `:linux` and are skipped on
# darwin, which is what the macOS CI smoke job (.github/workflows/macos.yml) runs.
#
# `WARDMAST_TEST_EXCLUDE_LINUX=1` applies the same exclusion on any host, so the
# macOS subset can be reproduced on Linux. An anonymous function rather than a
# module for the same reason as test_max_cases.exs: an umbrella-root `mix test`
# loads every helper into one VM.
fn env, os_type ->
  forced? = Map.get(env, "WARDMAST_TEST_EXCLUDE_LINUX") in ["1", "true"]

  if forced? or match?({:unix, :darwin}, os_type), do: [:linux], else: []
end
