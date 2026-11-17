# Shared by the wardmast, wardmast_web and wardmast_cli test helpers (bd-datu4q),
# via
#
#     tuning = "../../../scripts/test_host_tuning.exs" |> Path.expand(__DIR__) |> Code.eval_file() |> elem(0)
#     tuning.normalize_tmpdir.(System.get_env(), :os.type())   # FIRST, before any System.tmp_dir!/0
#     ExUnit.start(tuning.ex_unit_opts.(System.get_env(), :os.type()) ++ ...)
#
# Evaluates to a map of two functions. Both are no-ops on a plain Linux host; they
# apply on darwin (the macOS smoke job, .github/workflows/macos.yml) and wherever
# `WARDMAST_TEST_EXCLUDE_LINUX=1` reproduces that subset.
#
#   * `normalize_tmpdir.(env, os_type)`: on macOS `$TMPDIR` is
#     `/var/folders/...`, and `/var` is a symlink to `/private/var`. `git`,
#     `getcwd(3)` and a child's `$PWD` all report the *real* path, so every test
#     that builds a fixture under `System.tmp_dir!/0` and then compares it with
#     what git or a spawned process prints fails on a `/private` prefix. Replacing
#     `$TMPDIR` with its real path makes the two spellings the same string.
#     Returns the (possibly rewritten) tmp dir.
#
#   * `ex_unit_opts.(env, os_type)`: `ExUnit.start/1` options. The default
#     `assert_receive_timeout` is 100 ms, which LiveView's `render_async/2` and
#     friends also read; a shared 3-core macOS runner misses it on the first
#     async read. 1 s is still a bound (a test that never gets its message fails
#     in 1 s), it just stops a slow runner from reading as a regression.
#
# Anonymous functions in a map rather than a module for the same reason as
# test_max_cases.exs: an umbrella-root `mix test` loads every helper into one VM.
host_tuned? = fn env, os_type ->
  Map.get(env, "WARDMAST_TEST_EXCLUDE_LINUX") in ["1", "true"] or
    match?({:unix, :darwin}, os_type)
end

%{
  normalize_tmpdir: fn env, os_type ->
    tmp = System.tmp_dir!()

    if host_tuned?.(env, os_type) do
      # `getcwd(3)` after a chdir is the physical path, symlinks resolved.
      real =
        try do
          File.cd!(tmp, fn -> File.cwd!() end)
        rescue
          File.Error -> tmp
        end

      System.put_env("TMPDIR", real)
      real
    else
      tmp
    end
  end,
  ex_unit_opts: fn env, os_type ->
    if host_tuned?.(env, os_type), do: [assert_receive_timeout: 1_000], else: []
  end
}
