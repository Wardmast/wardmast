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
    File.mkdir_p!(repo)
    git!(dir, ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    repo
  end

  # main: base (lock L1), the branch: head.
  defp branch!(dir, head_files, base_files \\ %{"mix.lock" => "%{lock: 1}\n"}) do
    repo = repo!(dir)
    base = commit!(repo, Map.merge(%{"web/page.txt" => "v1"}, base_files), "base")
    git!(repo, ["checkout", "-q", "-b", "feature"])
    head = commit!(repo, Map.merge(%{"web/page.txt" => "v2"}, head_files), "head")
    {repo, base, head}
  end

  describe "plan/4: which lockfile is trusted" do
    test "an unchanged lockfile at a merge-base on the default branch: that commit", %{
      tmp_dir: dir
    } do
      {repo, base, head} = branch!(dir, %{})
      hash = :crypto.hash(:sha256, "%{lock: 1}\n") |> Base.encode16(case: :lower)

      assert {:ok, %{source: ^base, lock_hash: ^hash}} = DepsCache.plan(repo, base, head, "main")
    end

    test "a head that edits, adds or deletes mix.lock is skipped (deps_changed)", %{tmp_dir: dir} do
      {repo, base, head} = branch!(Path.join(dir, "edit"), %{"mix.lock" => "%{lock: 2}\n"})
      assert {:skip, reason} = DepsCache.plan(repo, base, head, "main")
      assert reason =~ "edits mix.lock"
      assert reason =~ "default branch"

      {repo, base, head} =
        branch!(Path.join(dir, "add"), %{"mix.lock" => "%{lock: 1}\n"}, %{"README" => "r"})

      assert {:skip, reason} = DepsCache.plan(repo, base, head, "main")
      assert reason =~ "adds a mix.lock"

      {repo, base, head} = branch!(Path.join(dir, "delete"), %{"mix.lock" => :delete})
      assert {:skip, reason} = DepsCache.plan(repo, base, head, "main")
      assert reason =~ "deletes mix.lock"
    end

    test "no lockfile at either commit: nothing to cache", %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{}, %{"README" => "r"})
      assert {:ok, :none} = DepsCache.plan(repo, base, head, "main")
    end

    test "a merge-base off the default branch: only when the default branch has that lockfile",
         %{tmp_dir: dir} do
      repo = repo!(dir)
      root = commit!(repo, %{"web/page.txt" => "v0", "mix.lock" => "%{lock: 1}\n"}, "root")
      # A release branch the PR targets, which main never merged.
      git!(repo, ["checkout", "-q", "-b", "release"])
      base = commit!(repo, %{"web/page.txt" => "r1"}, "release work")
      git!(repo, ["checkout", "-q", "-b", "feature"])
      head = commit!(repo, %{"web/page.txt" => "r2"}, "feature work")

      # main still has the same lockfile: its own tip is the trusted source.
      main_tip = git!(repo, ["rev-parse", "main"])
      assert main_tip == root
      assert {:ok, %{source: ^main_tip}} = DepsCache.plan(repo, base, head, "main")

      # main moved its lockfile on: nothing on the default branch vouches for this one.
      git!(repo, ["checkout", "-q", "main"])
      commit!(repo, %{"mix.lock" => "%{lock: 9}\n"}, "main bumps deps")
      assert {:skip, reason} = DepsCache.plan(repo, base, head, "main")
      assert reason =~ "default branch"
    end

    test "a default branch the repo does not have is an error, not a guess", %{tmp_dir: dir} do
      {repo, base, head} = branch!(dir, %{})
      assert {:error, message} = DepsCache.plan(repo, base, head, "trunk")
      assert message =~ "trunk"
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
      assert File.ls!(ctx.root) == [Path.basename(cache.dir)]
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

    test "a seed that fails is an error with its output, and publishes nothing", ctx do
      opts = Keyword.put(ctx.opts, :seed_script, "echo 'mix deps.get: nxdomain' >&2; exit 1")

      assert {:error, message} = DepsCache.prepare(input(ctx.repo, ctx.base, ctx.head), opts)
      assert message =~ "nxdomain"
      assert File.ls!(ctx.root) == []
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
