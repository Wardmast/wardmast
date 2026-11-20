defmodule Wardmast.Screenshots.Capture.DepsCacheTest do
  @moduledoc """
  The capture's offline Mix deps cache (bd-3glf2a): which lockfile it trusts (a default-branch
  commit's, never the head's), the `deps_changed` skip, seeding once per lockfile and toolchain
  in the sandbox's network-on mode, and, for real, a head checkout compiling from the read-only
  cache with no network and no Hex fetch. Runs under `CaptureHostSandbox` (no isolation, test
  support); `capture_sandbox_test.exs` does the compile inside a real bwrap.
  """

  use ExUnit.Case, async: false

  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.DepsCache
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Test.CaptureHostSandbox
  alias Wardmast.Test.CaptureNoSandbox

  @moduletag :tmp_dir

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(repo, files, message) do
    Enum.each(files, fn
      {path, :delete} ->
        File.rm!(Path.join(repo, path))

      {path, body} ->
        File.mkdir_p!(Path.dirname(Path.join(repo, path)))
        File.write!(Path.join(repo, path), body)
    end)

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp repo!(dir) do
    repo = Path.join(dir, "repo")
    forge = Path.join(dir, "forge.git")
    File.mkdir_p!(repo)
    git!(dir, ["init", "-q", "--bare", "-b", "main", forge])
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    git!(repo, ["remote", "add", "origin", forge])
    repo
  end

  # What origin's default branch is: the trust anchor (`git ls-remote`).
  defp push!(repo, branch \\ "main"), do: git!(repo, ["push", "-q", "origin", branch])

  # main (pushed to origin): base (lock L1); the branch: head.
  defp branch!(dir, head_files, base_files \\ %{"mix.lock" => "%{lock: 1}\n"}) do
    repo = repo!(dir)
    base = commit!(repo, Map.merge(%{"web/page.txt" => "v1"}, base_files), "base")
    push!(repo)
    git!(repo, ["checkout", "-q", "-b", "feature"])
    head = commit!(repo, Map.merge(%{"web/page.txt" => "v2"}, head_files), "head")
    {repo, base, head}
  end

  defp plan(repo, base, head, branch \\ "main"),
    do:
      DepsCache.plan(repo, base, head, branch, root: Path.join(Path.dirname(repo), "trust-root"))

  describe "plan/5: which lockfile is trusted" do
    test "an unchanged lockfile at a merge-base on the default branch: that commit", %{
      tmp_dir: dir
    } do
      {repo, base, head} = branch!(dir, %{})
      hash = :crypto.hash(:sha256, "%{lock: 1}\n") |> Base.encode16(case: :lower)

      assert {:ok, %{source: ^base, lock_hash: ^hash, repo: trusted}} = plan(repo, base, head)
      # The source lives in a repository of the server's own, outside the checkout.
      refute String.starts_with?(trusted, repo)
      assert {_, 0} = System.cmd("git", ["-C", trusted, "cat-file", "-e", base <> "^{commit}"])
    end

    test "a head that edits, adds or deletes mix.lock is skipped (deps_changed)", %{tmp_dir: dir} do
      {repo, base, head} = branch!(Path.join(dir, "edit"), %{"mix.lock" => "%{lock: 2}\n"})
      assert {:skip, reason} = plan(repo, base, head)
      assert reason =~ "edits mix.lock"
      assert reason =~ "default branch"

      {repo, base, head} =
        branch!(Path.join(dir, "add"), %{"mix.lock" => "%{lock: 1}\n"}, %{"README" => "r"})

      assert {:skip, reason} = plan(repo, base, head)
      assert reason =~ "adds a mix.lock"

      {repo, base, head} = branch!(Path.join(dir, "delete"), %{"mix.lock" => :delete})
      assert {:skip, reason} = plan(repo, base, head)
      assert reason =~ "deletes mix.lock"
    end

    test "no lockfile at either commit: nothing to cache", %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{}, %{"README" => "r"})
      assert {:ok, :none} = plan(repo, base, head)
    end

    test "a merge-base off the default branch: only when the default branch has that lockfile",
         %{tmp_dir: dir} do
      repo = repo!(dir)
      root = commit!(repo, %{"web/page.txt" => "v0", "mix.lock" => "%{lock: 1}\n"}, "root")
      push!(repo)
      # A release branch the PR targets, which main never merged.
      git!(repo, ["checkout", "-q", "-b", "release"])
      base = commit!(repo, %{"web/page.txt" => "r1"}, "release work")
      git!(repo, ["checkout", "-q", "-b", "feature"])
      head = commit!(repo, %{"web/page.txt" => "r2"}, "feature work")

      # main still has the same lockfile: its own tip is the trusted source.
      assert {:ok, %{source: ^root}} = plan(repo, base, head)

      # main moved its lockfile on: nothing on the default branch vouches for this one.
      git!(repo, ["checkout", "-q", "main"])
      commit!(repo, %{"mix.lock" => "%{lock: 9}\n"}, "main bumps deps")
      push!(repo)
      assert {:skip, reason} = plan(repo, base, head)
      assert reason =~ "default branch"
    end

    test "a default branch origin does not have is an error, not a guess", %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{})
      assert {:error, message} = plan(repo, base, head, "trunk")
      assert message =~ "trunk"
    end

    # The tip is read live from origin, so it can be one the checkout has not fetched yet: the
    # checkout fetches it from origin once, and only then is it taken into the trusted repository.
    test "a default branch tip the checkout has not fetched yet is fetched from origin first", %{
      tmp_dir: dir
    } do
      {repo, base, head} = branch!(dir, %{})
      other = Path.join(dir, "other")
      git!(dir, ["clone", "-q", Path.join(dir, "forge.git"), other])
      git!(other, ["config", "user.email", "t@example.com"])
      git!(other, ["config", "user.name", "t"])
      tip = commit!(other, %{"web/page.txt" => "v1.1"}, "main moves on")
      push!(other)

      assert {_, status} =
               System.cmd("git", ["-C", repo, "cat-file", "-e", tip <> "^{commit}"],
                 stderr_to_stdout: true
               )

      refute status == 0

      assert {:ok, %{source: ^base, repo: trusted}} = plan(repo, base, head)
      assert {_, 0} = System.cmd("git", ["-C", trusted, "cat-file", "-e", tip <> "^{commit}"])
    end

    # The worker's refs are writable from its jail: moving its `origin/main` (and `main`) onto a
    # commit of its own, with the same lockfile and a mix.exs of its choosing, must not make that
    # commit the one the seed runs with the network on.
    test "a worker that moves its own origin/main cannot choose the source", %{tmp_dir: dir} do
      repo = repo!(dir)
      tip = commit!(repo, %{"web/page.txt" => "v1", "mix.lock" => "%{lock: 1}\n"}, "main")
      push!(repo)
      git!(repo, ["checkout", "-q", "-b", "evil"])
      evil = commit!(repo, %{"mix.exs" => "System.cmd(\"curl\", [\"evil\"])"}, "evil mix.exs")
      git!(repo, ["update-ref", "refs/remotes/origin/main", evil])
      git!(repo, ["update-ref", "refs/heads/main", evil])
      git!(repo, ["checkout", "-q", "-b", "feature"])
      head = commit!(repo, %{"web/page.txt" => "v2"}, "feature")

      # The local merge-base with the doctored origin/main is the worker's own commit...
      assert git!(repo, ["merge-base", "origin/main", "HEAD"]) == evil

      # ...but the source is origin's real tip, and the worker's commit never enters the trusted
      # repository.
      assert {:ok, %{source: ^tip, repo: trusted}} = plan(repo, evil, head)

      assert {_, status} =
               System.cmd("git", ["-C", trusted, "cat-file", "-e", evil], stderr_to_stdout: true)

      refute status == 0
    end

    # The worker's object store is writable too: an object forged under the trusted tip's name
    # never reaches the trusted repository, so the seed fails closed instead of running it.
    test "an object forged in the worker's store fails closed", %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{})
      blob = git!(repo, ["rev-parse", base <> ":web/page.txt"])

      loose =
        Path.join([repo, ".git", "objects", binary_part(blob, 0, 2), binary_part(blob, 2, 38)])

      assert File.regular?(loose)
      forged = "System.cmd(\"curl\", [\"evil\"])\n"
      File.chmod!(loose, 0o644)
      File.write!(loose, :zlib.compress("blob #{byte_size(forged)}\0" <> forged))

      assert {:error, message} = plan(repo, base, head)
      assert message =~ "trusted repository"
    end
  end

  # A fake seed: proves where it ran (the tree's page) and that it had the cache's paths.
  @fake_seed """
  set -e
  mkdir -p "$MIX_DEPS_PATH/fake" "$MIX_HOME" "$HEX_HOME" _build
  cat web/page.txt > "$MIX_DEPS_PATH/fake/tree"
  echo "$MIX_ENV" > "$MIX_DEPS_PATH/fake/env"
  printf '#!/bin/sh\\necho esbuild\\n' > _build/esbuild-linux-x64
  chmod +x _build/esbuild-linux-x64
  echo seeded >> "$SEED_LOG"
  """

  defp input(repo, base, head, extra \\ %{}) do
    Map.merge(
      %{
        task_id: "bd-deps",
        repo_path: repo,
        base_sha: base,
        head_sha: head,
        default_branch: "main",
        sandbox: CaptureHostSandbox,
        readonly_paths: [],
        timeout_s: 120
      },
      extra
    )
  end

  describe "prepare/2" do
    setup %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{})
      root = Path.join(dir, "cache-root")
      log = Path.join(dir, "seed.log")
      opts = [root: root, seed_script: @fake_seed, seed_env: [{"SEED_LOG", log}]]
      %{repo: repo, base: base, head: head, root: root, log: log, opts: opts}
    end

    test "a miss seeds once, in the trusted tree, with the network on; then it is a hit", ctx do
      assert {:ok, cache} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), ctx.opts)

      # It ran through the sandbox's network-on command, in the merge-base's tree (v1, not v2).
      assert_received {:fetch_command, _argv, box}
      assert box.checkout =~ ctx.root
      assert File.read!(Path.join(cache.dir, "deps/fake/tree")) == "v1"
      assert File.read!(Path.join(cache.dir, "deps/fake/env")) == "dev\n"
      assert File.regular?(Path.join(cache.dir, ".complete"))
      assert Path.dirname(cache.dir) == ctx.root

      assert {:ok, ^cache} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), ctx.opts)
      refute_received {:fetch_command, _, _}
      assert File.read!(ctx.log) == "seeded\n"

      # Nothing of the seed's work is left beside the cache.
      assert Enum.reject(File.ls!(ctx.root), &(&1 == "repos")) == [Path.basename(cache.dir)]
    end

    test "the boot is pointed at the cache: offline, and the asset tools linked", ctx do
      assert {:ok, cache} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), ctx.opts)
      env = Map.new(cache.env)

      assert env["MIX_DEPS_PATH"] == Path.join(cache.dir, "deps")
      assert env["MIX_HOME"] == Path.join(cache.dir, "mix")
      assert env["HEX_HOME"] == Path.join(cache.dir, "hex")
      assert env["HEX_OFFLINE"] == "1"
      assert env["ELIXIR_MAKE_CACHE_DIR"] == Path.join(cache.dir, "cache/elixir_make")

      assert env["RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"] ==
               Path.join(cache.dir, "cache/rustler_precompiled")

      esbuild = Path.join(cache.dir, "bin/esbuild-linux-x64")
      assert env["MIX_ESBUILD_PATH"] == esbuild
      refute Map.has_key?(env, "MIX_TAILWIND_PATH")
      assert cache.links == [{"_build/esbuild-linux-x64", esbuild}]
      assert File.regular?(esbuild)

      # Every name it sets is one the config refuses in `env` (Config.deps_env_names/0).
      assert Map.keys(env) -- Wardmast.Screenshots.Config.deps_env_names() == []
    end

    test "the seed gets the server's proxy, never one that carries credentials", ctx do
      saved =
        Map.new(~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy), &{&1, System.get_env(&1)})

      System.put_env("HTTPS_PROXY", "http://proxy.internal:3128")
      System.put_env("HTTP_PROXY", "http://user:hunter2@proxy.internal:3128")
      System.delete_env("https_proxy")
      System.delete_env("http_proxy")

      on_exit(fn ->
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      seen = Path.join(ctx.root <> "-env", "env.txt")
      File.mkdir_p!(Path.dirname(seen))
      script = ~s(env > "#{seen}"\n) <> @fake_seed

      assert {:ok, _} =
               DepsCache.prepare(
                 input(ctx.repo, ctx.base, ctx.head),
                 Keyword.put(ctx.opts, :seed_script, script)
               )

      env = File.read!(seen)
      assert env =~ ~r/^HTTPS_PROXY=http:\/\/proxy.internal:3128$/m
      refute env =~ "hunter2"
      refute env =~ ~r/^HTTP_PROXY=/m
    end

    # Whatever the seed leaves is untrusted to the host: a symlink it plants is never followed by
    # the host-side copy, write or rename that publishes the cache.
    test "a seed's symlinks are never followed by the host", %{tmp_dir: dir} = ctx do
      secret = Path.join(dir, "server-secret")
      File.write!(secret, "SECRET")
      victim = Path.join(dir, "victim-dir")
      File.mkdir_p!(victim)

      script = """
      set -e
      mkdir -p "$MIX_DEPS_PATH" _build
      ln -s "#{secret}" _build/esbuild-linux-x64
      ln -s "#{victim}" "$MIX_DEPS_PATH/../bin"
      ln -s "#{secret}" "$MIX_DEPS_PATH/../.complete"
      """

      assert {:ok, cache} =
               DepsCache.prepare(
                 input(ctx.repo, ctx.base, ctx.head),
                 Keyword.put(ctx.opts, :seed_script, script)
               )

      # The planted tool was not copied (it is not a regular file), so no tool env or link...
      refute Enum.any?(cache.env, &match?({"MIX_ESBUILD_PATH", _}, &1))
      assert cache.links == []
      # ...nothing was written through the planted links, and the cache's own bin and stamp are
      # real.
      assert File.read!(secret) == "SECRET"
      assert File.ls!(victim) == []
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(cache.dir, "bin"))
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(cache.dir, ".complete"))
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(cache.dir)
    end

    test "a seed that swaps a cache directory for a symlink publishes nothing",
         %{tmp_dir: dir} = ctx do
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      script = ~s(set -e\nrm -rf "$MIX_DEPS_PATH"\nln -s \"#{elsewhere}\" "$MIX_DEPS_PATH"\n)

      assert {:error, message} =
               DepsCache.prepare(
                 input(ctx.repo, ctx.base, ctx.head),
                 Keyword.put(ctx.opts, :seed_script, script)
               )

      assert message =~ "deps"
      assert Enum.reject(File.ls!(ctx.root), &(&1 == "repos")) == []
    end

    test "a seed that fails is an error with its output, and publishes nothing", ctx do
      opts = Keyword.put(ctx.opts, :seed_script, "echo 'mix deps.get: nxdomain' >&2; exit 1")

      assert {:error, message} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), opts)
      assert message =~ "nxdomain"
      assert Enum.reject(File.ls!(ctx.root), &(&1 == "repos")) == []
    end

    # The ReviewGate cancels a capture when a newer head arrives (bd-8qj1sa), and a shutdown stops
    # it, both as `Task.Supervisor.terminate_child/2` does: the seed dies without its `after`.
    test "a seed killed with its capture leaves nothing once its lockfile is seeded again", ctx do
      input = input(ctx.repo, ctx.base, ctx.head)
      held = Keyword.put(ctx.opts, :seed_script, "exec sleep 60")

      pid =
        spawn(fn ->
          receive do
            :go -> DepsCache.prepare(input, held)
          end
        end)

      # The sandbox is asked for the seed's command once its work directory exists.
      :erlang.trace(pid, true, [:send])
      send(pid, :go)
      assert_receive {:trace, ^pid, :send, {:fetch_command, _argv, box}, ^pid}, 60_000

      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
      assert File.dir?(Path.dirname(box.checkout)), "the killed seed's work is left behind"

      assert {:ok, cache} = DepsCache.prepare(input, ctx.opts)
      assert Enum.reject(File.ls!(ctx.root), &(&1 == "repos")) == [Path.basename(cache.dir)]
    end

    test "after a seed, work a long-dead run left is pruned; a recent one may be live and stays",
         ctx do
      long_ago = System.os_time(:second) - 15 * 86_400
      old_seed = Path.join(ctx.root, "seed-0123456789ab-0123456789ab-0123456789ab")
      old_probe = Path.join(ctx.root, "probe-0123456789ab")
      recent = Path.join(ctx.root, "seed-ba9876543210-ba9876543210-ba9876543210")

      for dir <- [old_seed, old_probe, recent], do: File.mkdir_p!(Path.join(dir, "out/ro"))
      # A compiled tree can hold read-only directories.
      File.write!(Path.join(old_seed, "out/ro/file"), "x")
      File.chmod!(Path.join(old_seed, "out/ro"), 0o555)
      on_exit(fn -> File.chmod(Path.join(old_seed, "out/ro"), 0o755) end)
      for dir <- [old_seed, old_probe], do: File.touch!(dir, long_ago)

      assert {:ok, _cache} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), ctx.opts)
      refute File.exists?(old_seed)
      refute File.exists?(old_probe)
      assert File.dir?(recent)
    end

    test "a head that changes mix.lock never seeds anything", ctx do
      head = commit!(ctx.repo, %{"mix.lock" => "%{lock: 2}\n"}, "bump")

      assert {:skip, _} = DepsCache.prepare(input(ctx.repo, ctx.base, head), ctx.opts)
      refute_received {:fetch_command, _, _}
      refute File.exists?(ctx.root) and File.ls!(ctx.root) != []
    end

    test "no lockfile: no cache, and nothing runs", %{tmp_dir: dir} = ctx do
      {repo, base, head} = branch!(Path.join(dir, "nolock"), %{}, %{"README" => "r"})
      assert {:ok, nil} = DepsCache.prepare(input(repo, base, head), ctx.opts)
      refute_received {:fetch_command, _, _}
    end

    test "a sandbox that cannot fetch is an error", ctx do
      assert {:error, message} =
               DepsCache.prepare(
                 input(ctx.repo, ctx.base, ctx.head, %{sandbox: CaptureNoSandbox}),
                 ctx.opts
               )

      assert message =~ "fetch"
    end
  end

  describe "offline compile, for real" do
    @describetag timeout: 300_000

    # A dependency fetched with no network at all: a local git repo.
    defp dep_repo!(dir) do
      dep = Path.join(dir, "tiny_dep")
      File.mkdir_p!(Path.join(dep, "lib"))
      git!(dir, ["init", "-q", "-b", "main", dep])
      git!(dep, ["config", "user.email", "t@example.com"])
      git!(dep, ["config", "user.name", "t"])

      commit!(
        dep,
        %{
          "mix.exs" => """
          defmodule Tiny.MixProject do
            use Mix.Project
            def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
          end
          """,
          "lib/tiny.ex" => "defmodule Tiny do\n  def hello, do: :from_the_cache\nend\n"
        },
        "tiny"
      )

      git!(dep, ["tag", "v1"])
      dep
    end

    defp mix_env(home), do: [{"PATH", Sandbox.path()}, {"HOME", home}, {"LANG", "C.UTF-8"}]

    defp run!(argv, cd, env) do
      {:ok, pid} = AppProcess.start_link(%{argv: argv, cd: cd, env: env})

      try do
        AppProcess.await_exit(pid, 240_000)
      after
        AppProcess.stop(pid)
      end
    end

    test "a head checkout compiles from the read-only cache, with Hex offline", %{tmp_dir: dir} do
      mix = System.find_executable("mix")
      dep = dep_repo!(dir)
      repo = repo!(dir)
      home = Path.join(dir, "home")
      File.mkdir_p!(home)

      app = %{
        "mix.exs" => """
        defmodule App.MixProject do
          use Mix.Project
          def project, do: [app: :app, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
          defp deps, do: [{:tiny, git: "file://#{dep}", tag: "v1"}]
        end
        """,
        "lib/app.ex" => "defmodule App do\n  def hi, do: Tiny.hello()\nend\n",
        "web/page.txt" => "v1"
      }

      Enum.each(app, fn {path, body} ->
        File.mkdir_p!(Path.dirname(Path.join(repo, path)))
        File.write!(Path.join(repo, path), body)
      end)

      # The lockfile, as the default branch committed it.
      assert {:exited, 0, _} = run!([mix, "deps.get"], repo, mix_env(home))
      File.rm_rf!(Path.join(repo, "deps"))
      File.rm_rf!(Path.join(repo, "_build"))
      assert File.read!(Path.join(repo, "mix.lock")) =~ "tiny"
      base = commit!(repo, %{}, "base")
      push!(repo)
      git!(repo, ["checkout", "-q", "-b", "feature"])
      head = commit!(repo, %{"web/page.txt" => "v2"}, "head")

      root = Path.join(dir, "cache-root")
      assert {:ok, cache} = DepsCache.prepare(input(repo, base, head), root: root)
      assert File.dir?(Path.join(cache.dir, "deps/tiny"))

      # The boot: the head's tree, no deps of its own, the cache read-only, no network settings.
      boot = Path.join(dir, "boot")
      File.mkdir_p!(boot)
      {_, 0} = System.cmd("sh", ["-c", "git -C '#{repo}' archive #{head} | tar -x -C '#{boot}'"])
      {_, 0} = System.cmd("chmod", ["-R", "a-w", cache.dir])
      on_exit(fn -> System.cmd("chmod", ["-R", "u+w", cache.dir]) end)

      env = mix_env(home) ++ cache.env

      assert {:exited, 0, out} =
               run!([mix, "run", "-e", "IO.puts(App.hi())"], boot, env),
             "the offline compile failed"

      assert out =~ "from_the_cache"
      refute File.exists?(Path.join(boot, "deps"))
      assert File.dir?(Path.join(boot, "_build/dev/lib/tiny/ebin"))
    end
  end
end
