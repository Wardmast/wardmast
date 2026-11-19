defmodule Wardmast.Screenshots.Capture.DepsCache do
  @moduledoc """
  The capture's offline Mix dependency cache (bd-3glf2a, `screenshots.deps.mix`; design
  `docs/design/ui-screenshot-capture.md` §2, "Offline deps").

  A capture boot runs in a sandbox with no network (`Capture.Sandbox`), so its `setup_cmd` cannot
  `mix deps.get` or download esbuild/tailwind. This module fetches them **beforehand, from a
  trusted lockfile only**, into a directory every boot then sees read-only.

  ## Which lockfile is trusted (`plan/4`)

  Only a `mix.lock` the **default branch** has had. The merge-base is the base boot's own tree;
  when it is an ancestor of the default branch, its lockfile is that, and it is the source. When
  it is not (a PR into another branch), the default branch's tip is the source, if its lockfile is
  byte-for-byte the same. The head's lockfile must equal the source's: a head that edits, adds or
  deletes `mix.lock` is `{:skip, reason}` (`skip_kind: deps_changed`), and nothing is fetched for
  it. **The head's own `mix.exs` and lockfile never run with a network.** Running the source's
  (`mix deps.get` evaluates the project's `mix.exs`) is the same trust as merging it.

  ## The cache (`prepare/2`)

  `<root>/<lock12>-<toolchain12>` (`root` default `<scratch_root>/capture-deps`): the lock's
  SHA-256, and a fingerprint of the toolchain the boot will use (Elixir, OTP, ERTS and the
  architecture, as `elixir` reports them **inside the capture sandbox**, so it is the one the
  boots run). Hex and rebar3 archives and precompiled NIFs are bound to that toolchain, so a new
  one misses the cache. A miss seeds it, once per key (`:global.trans/4`):

    1. `git archive` of the source commit (no `.git`, nothing a worker wrote);
    2. `seed_script/0` in it, through the sandbox's `fetch_command/2`: the same filesystem
       allowlist as a boot (its `readonly_paths` too) **with the network on**, an environment
       built from nothing (plus the server's own proxy variables, never one with a credential in
       it), `MIX_ENV=dev`:
       `mix local.hex`/`local.rebar` (when the lock needs them), `mix deps.get`, `mix
       deps.compile` (which also downloads precompiled NIFs, `elixir_make` and
       `rustler_precompiled`, into the cache), then `mix esbuild.install`/`tailwind.install`
       when the deps include them;
    3. the results (`deps/`, `mix/`, `hex/`, `cache/`, `bin/esbuild-*`, `bin/tailwind-*`) are
       published by an atomic rename with a `.complete` stamp. A failed seed leaves nothing.

  The source's `_build` is discarded: each boot compiles into its own checkout.

  ## What a boot gets

  The cache directory read-only (`box.cache_dirs`), and these variables (which `env` may not set
  while `deps.mix` is on, `Screenshots.Config.deps_env_names/0`):

  | variable | value |
  |---|---|
  | `MIX_DEPS_PATH` | `<cache>/deps` |
  | `MIX_HOME` / `HEX_HOME` | `<cache>/mix` / `<cache>/hex` (Hex and rebar3) |
  | `HEX_OFFLINE` | `1` |
  | `ELIXIR_MAKE_CACHE_DIR`, `RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH` | `<cache>/cache/…` |
  | `MIX_ESBUILD_PATH`, `MIX_TAILWIND_PATH` | `<cache>/bin/<tool>-<target>`, when installed |

  and `_build/<tool>-<target>` in its checkout linked to that binary, where a stock Phoenix
  config looks for it. A dependency that writes into its own source directory while compiling
  cannot (it is read-only); the precompiled NIFs the seed fetched are what keeps `exqlite`,
  `mdex` and the like working.

  ## Options

  `:root`, `:seed_script` and `:seed_env` (`[{name, value}]` added to the seed's environment;
  tests), `:keep_days` (completed caches unused that long are pruned after a seed; default 14).
  """

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Worker.Image
  alias Wardmast.Worker.ReleaseEnv

  require Logger

  @complete ".complete"
  @fingerprint_timeout_ms 60_000
  @git_timeout_ms 120_000
  @proxy_env ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)
  @keep_days 14

  @seed_script """
  set -e
  if [ "$ARB_NEED_HEX" = 1 ]; then mix local.hex --force; fi
  if [ "$ARB_NEED_REBAR" = 1 ]; then mix local.rebar --force; fi
  mix deps.get
  mix deps.compile
  if [ -d "$MIX_DEPS_PATH/esbuild" ]; then
    mix esbuild.install --if-missing || echo "capture deps: mix esbuild.install failed; the boots go without it" >&2
  fi
  if [ -d "$MIX_DEPS_PATH/tailwind" ]; then
    mix tailwind.install --if-missing || echo "capture deps: mix tailwind.install failed; the boots go without it" >&2
  fi
  """

  @fingerprint_code """
  IO.puts("elixir=" <> System.version())
  IO.puts("otp=" <> List.to_string(:erlang.system_info(:otp_release)))
  IO.puts("erts=" <> List.to_string(:erlang.system_info(:version)))
  IO.puts("arch=" <> List.to_string(:erlang.system_info(:system_architecture)))
  """

  @type cache :: %{
          dir: String.t(),
          env: [{String.t(), String.t()}],
          links: [{String.t(), String.t()}]
        }

  @doc "What the seed runs in the source tree (for the docs and tests)."
  @spec seed_script() :: String.t()
  def seed_script, do: @seed_script

  # ── plan ────────────────────────────────────────────────────────────────

  @doc """
  The trusted lockfile for a capture of `base..head` in `repo`: `{:ok, %{source:, lock_hash:,
  lock:}}` (the commit to seed from), `{:ok, :none}` (no `mix.lock` at either commit), `{:skip,
  reason}` (the head's lockfile is not one the default branch vouches for) or `{:error, message}`.
  """
  @spec plan(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :none | %{source: String.t(), lock_hash: String.t(), lock: binary()}}
          | {:skip, String.t()}
          | {:error, String.t()}
  def plan(repo, base, head, default_branch) do
    case {lock_at(repo, base), lock_at(repo, head)} do
      {:none, :none} -> {:ok, :none}
      {same, same} -> trusted_source(repo, base, same, default_branch)
      {:none, _} -> {:skip, changed("adds a mix.lock")}
      {_, :none} -> {:skip, changed("deletes mix.lock")}
      _ -> {:skip, changed("edits mix.lock")}
    end
  end

  defp changed(what) do
    "the change #{what}; a capture boot has no network and only gets dependencies fetched from " <>
      "a lockfile the default branch has had, so it cannot boot this change (its own mix.exs " <>
      "and lockfile never run with a network)"
  end

  defp trusted_source(repo, base, {:ok, lock}, branch) do
    with {:ok, ref} <- default_ref(repo, branch) do
      cond do
        ancestor?(repo, base, ref) ->
          {:ok, %{source: base, lock_hash: digest(lock), lock: lock}}

        lock_at(repo, ref) == {:ok, lock} ->
          {:ok, %{source: rev_parse!(repo, ref), lock_hash: digest(lock), lock: lock}}

        true ->
          {:skip,
           "this change's mix.lock is not one the default branch (#{branch}) has: its merge-base " <>
             "is not on #{branch} and #{branch}'s own lockfile differs. A capture boot only gets " <>
             "dependencies fetched from a default-branch lockfile"}
      end
    end
  end

  defp default_ref(repo, branch) do
    case Image.default_ref(repo, branch) do
      {:ok, ref} ->
        {:ok, ref}

      {:error, reason} ->
        {:error,
         "cannot find the default branch #{inspect(branch)} in #{repo} to check the lockfile " <>
           "against (#{inspect(reason)})"}
    end
  end

  defp lock_at(repo, rev) do
    case git(repo, ["cat-file", "blob", rev <> ":mix.lock"]) do
      {body, 0} -> {:ok, body}
      _ -> :none
    end
  end

  defp ancestor?(repo, base, ref),
    do: match?({_, 0}, git(repo, ["merge-base", "--is-ancestor", base, ref]))

  defp rev_parse!(repo, ref) do
    {out, 0} = git(repo, ["rev-parse", "--verify", ref <> "^{commit}"])
    String.trim(out)
  end

  # ── prepare ─────────────────────────────────────────────────────────────

  @doc """
  The cache for a capture: `{:ok, cache}`, `{:ok, nil}` (nothing to cache), `{:skip, reason}`
  (`deps_changed`) or `{:error, message}`. `input` is `%{repo_path:, base_sha:, head_sha:,
  default_branch:, sandbox:, readonly_paths:, timeout_s:}`.
  """
  @spec prepare(map(), keyword()) ::
          {:ok, cache() | nil} | {:skip, String.t()} | {:error, String.t()}
  def prepare(input, opts \\ []) do
    with :ok <- can_fetch(input.sandbox),
         {:ok, %{} = source} <-
           plan(input.repo_path, input.base_sha, input.head_sha, input.default_branch),
         root = root(opts),
         :ok <- mkdir(root),
         {:ok, toolchain} <- fingerprint(input, source, root) do
      dir = Path.join(root, binary_part(source.lock_hash, 0, 12) <> "-" <> toolchain)

      with :ok <- ensure(dir, input, source, opts) do
        {:ok, cache(dir)}
      end
    else
      {:ok, :none} -> {:ok, nil}
      other -> other
    end
  end

  defp can_fetch(sandbox) do
    Code.ensure_loaded(sandbox)

    if function_exported?(sandbox, :fetch_command, 2),
      do: :ok,
      else:
        {:error,
         "the capture sandbox #{inspect(sandbox)} cannot fetch dependencies (no fetch_command/2)"}
  end

  defp root(opts),
    do: Keyword.get_lazy(opts, :root, fn -> Path.join(Paths.scratch_root(), "capture-deps") end)

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # The toolchain the boots will run: `elixir` inside the sandbox, from a directory holding only the
  # source's `.tool-versions` (what an asdf or mise shim would read in the checkout).
  defp fingerprint(input, source, root) do
    probe = Path.join(root, "probe-" <> token())
    home = Path.join(probe, ".home")

    try do
      File.mkdir_p!(home)

      case git(input.repo_path, ["cat-file", "blob", source.source <> ":.tool-versions"]) do
        {versions, 0} -> File.write!(Path.join(probe, ".tool-versions"), versions)
        _ -> :ok
      end

      box = %{checkout: probe, scratch: probe, readonly_paths: input.readonly_paths}
      env = [{"PATH", Sandbox.path()}, {"HOME", home}, {"LANG", "C.UTF-8"}]
      argv = ["elixir", "-e", @fingerprint_code]

      case sandboxed(&input.sandbox.command(&1, &2, nil), argv, box, env, @fingerprint_timeout_ms) do
        {:ok, out} ->
          lines = out |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/\A(elixir|otp|erts|arch)=/))

          if length(lines) == 4,
            do: {:ok, binary_part(digest(Enum.join(lines, "\n")), 0, 12)},
            else: {:error, fingerprint_error(out)}

        {:error, detail} ->
          {:error, fingerprint_error(detail)}
      end
    after
      File.rm_rf(probe)
    end
  end

  defp fingerprint_error(detail) do
    "could not run elixir in the capture sandbox to key the deps cache: #{tail(detail)} (a " <>
      "toolchain outside the system directories must be listed in screenshots.sandbox." <>
      "readonly_paths)"
  end

  defp ensure(dir, input, source, opts) do
    if complete?(dir) do
      touch(dir)
    else
      :global.trans({{__MODULE__, dir}, self()}, fn -> seed_once(dir, input, source, opts) end, [
        node()
      ])
    end
  end

  defp complete?(dir), do: File.regular?(Path.join(dir, @complete))

  # A hit marks the cache used, which keeps it from the prune.
  defp touch(dir) do
    _ = File.touch(Path.join(dir, @complete))
    :ok
  end

  defp seed_once(dir, input, source, opts) do
    if complete?(dir), do: touch(dir), else: seed(dir, input, source, opts)
  end

  defp seed(dir, input, source, opts) do
    work = Path.join(Path.dirname(dir), "seed-" <> token())
    src = Path.join(work, "src")
    scratch = Path.join(work, "scratch")
    out = Path.join(scratch, "out")

    try do
      Enum.each(
        [src, Path.join(scratch, "home"), Path.join(scratch, "tmp"), out],
        &File.mkdir_p!/1
      )

      with :ok <- export(input.repo_path, source.source, work, src),
           :ok <- run_seed(input, source, src, scratch, out, opts),
           :ok <- collect_tools(src, out),
           :ok <- publish(out, dir, source) do
        Logger.info("Capture.DepsCache: seeded #{dir} from #{String.slice(source.source, 0, 12)}")
        prune(Path.dirname(dir), dir, Keyword.get(opts, :keep_days, @keep_days))
        :ok
      end
    after
      force_rm_rf(work)
    end
  end

  defp export(repo, sha, work, src) do
    tar = Path.join(work, "tree.tar")

    with {_, 0} <- git(repo, ["archive", "--format=tar", "-o", tar, sha]),
         {_, 0} <- ReleaseEnv.cmd("tar", ["-xf", tar, "-C", src], stderr_to_stdout: true) do
      File.rm(tar)
      :ok
    else
      {output, _} -> {:error, "could not export #{String.slice(sha, 0, 12)}: #{tail(output)}"}
    end
  end

  defp run_seed(input, source, src, scratch, out, opts) do
    script = Keyword.get(opts, :seed_script, @seed_script)
    box = %{checkout: src, scratch: scratch, readonly_paths: input.readonly_paths}

    env =
      [
        {"PATH", Sandbox.path()},
        {"HOME", Path.join(scratch, "home")},
        {"LANG", "C.UTF-8"},
        {"TMPDIR", Path.join(scratch, "tmp")},
        {"MIX_ENV", "dev"},
        {"ARB_NEED_HEX", flag(source.lock =~ "{:hex,")},
        {"ARB_NEED_REBAR", flag(source.lock =~ ":rebar3")}
      ] ++ proxy_env() ++ seed_paths(out) ++ Keyword.get(opts, :seed_env, [])

    timeout = Map.get(input, :timeout_s, 600) * 1000

    case sandboxed(&input.sandbox.fetch_command(&1, &2), ["sh", "-c", script], box, env, timeout) do
      {:ok, _} ->
        :ok

      {:error, detail} ->
        {:error, "fetching the Mix deps for the capture failed: #{tail(detail)}"}
    end
  end

  defp flag(true), do: "1"
  defp flag(false), do: "0"

  # The trusted seed reaches the network the way the server does, but never with a proxy
  # credential: a URL with userinfo (`user:pass@`) stays with the server.
  defp proxy_env do
    for name <- @proxy_env,
        value = System.get_env(name),
        value not in [nil, ""],
        not String.contains?(value, "@"),
        do: {name, value}
  end

  defp seed_paths(out) do
    [
      {"MIX_DEPS_PATH", Path.join(out, "deps")},
      {"MIX_HOME", Path.join(out, "mix")},
      {"HEX_HOME", Path.join(out, "hex")},
      {"ELIXIR_MAKE_CACHE_DIR", Path.join(out, "cache/elixir_make")},
      {"RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(out, "cache/rustler_precompiled")}
    ]
  end

  # `mix esbuild.install` / `tailwind.install` put their binary next to `_build/<env>`.
  defp collect_tools(src, out) do
    bin = Path.join(out, "bin")
    File.mkdir_p!(bin)

    for file <- Path.wildcard(Path.join(src, "_build/{esbuild,tailwind}-*")),
        File.regular?(file) do
      File.cp!(file, Path.join(bin, Path.basename(file)))
      File.chmod!(Path.join(bin, Path.basename(file)), 0o755)
    end

    :ok
  rescue
    e in File.Error -> {:error, "could not keep the asset tools: #{Exception.message(e)}"}
  end

  # Every directory the boots are pointed at exists, then the stamp, then the atomic rename: the
  # final name only ever appears complete.
  defp publish(out, dir, source) do
    ~w(deps mix hex cache/elixir_make cache/rustler_precompiled bin)
    |> Enum.each(&File.mkdir_p!(Path.join(out, &1)))

    File.write!(
      Path.join(out, @complete),
      "lock=#{source.lock_hash}\nsource=#{source.source}\n"
    )

    case File.rename(out, dir) do
      :ok ->
        :ok

      {:error, reason} ->
        if complete?(dir),
          do: :ok,
          else: {:error, "could not publish the deps cache #{dir}: #{:file.format_error(reason)}"}
    end
  rescue
    e in File.Error -> {:error, "could not publish the deps cache: #{Exception.message(e)}"}
  end

  # Completed caches nobody used for `days` (another lockfile, an old toolchain). Never `keep`.
  defp prune(root, keep, days) do
    cutoff = System.os_time(:second) - days * 86_400

    for entry <- File.ls!(root),
        path = Path.join(root, entry),
        path != keep,
        Regex.match?(~r/\A[0-9a-f]{12}-[0-9a-f]{12}\z/, entry),
        stale?(Path.join(path, @complete), cutoff) do
      force_rm_rf(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp stale?(stamp, cutoff) do
    case File.stat(stamp, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
  end

  defp cache(dir) do
    tools = dir |> Path.join("bin") |> File.ls!() |> Enum.sort()

    env =
      [
        {"MIX_DEPS_PATH", Path.join(dir, "deps")},
        {"MIX_HOME", Path.join(dir, "mix")},
        {"HEX_HOME", Path.join(dir, "hex")},
        {"HEX_OFFLINE", "1"},
        {"ELIXIR_MAKE_CACHE_DIR", Path.join(dir, "cache/elixir_make")},
        {"RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH", Path.join(dir, "cache/rustler_precompiled")}
      ] ++
        tool_env(tools, "esbuild-", "MIX_ESBUILD_PATH", dir) ++
        tool_env(tools, "tailwind-", "MIX_TAILWIND_PATH", dir)

    %{
      dir: dir,
      env: env,
      links: Enum.map(tools, &{Path.join("_build", &1), Path.join([dir, "bin", &1])})
    }
  end

  defp tool_env(tools, prefix, var, dir) do
    case Enum.find(tools, &String.starts_with?(&1, prefix)) do
      nil -> []
      tool -> [{var, Path.join([dir, "bin", tool])}]
    end
  end

  # ── running in the sandbox ──────────────────────────────────────────────

  defp sandboxed(wrap, argv, box, env, timeout_ms) do
    case wrap.(argv, box) do
      {:ok, boxed} -> run(boxed, box.checkout, env, timeout_ms)
      {:error, reason} -> {:error, "the capture sandbox refused to run it: #{inspect(reason)}"}
    end
  end

  defp run(argv, cd, env, timeout_ms) do
    case AppProcess.start_link(%{argv: argv, cd: cd, env: env}) do
      {:ok, pid} ->
        try do
          case AppProcess.await_exit(pid, timeout_ms) do
            {:exited, 0, output} ->
              {:ok, output}

            {:exited, code, output} ->
              {:error, "exit #{code}: #{output}"}

            {:timeout, output} ->
              {:error, "timed out after #{div(timeout_ms, 1000)} s: #{output}"}
          end
        after
          AppProcess.stop(pid)
        end

      {:error, reason} ->
        {:error, "could not start it: #{inspect(reason)}"}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp git(repo, args) do
    task =
      Task.async(fn ->
        case System.find_executable("git") do
          nil -> {"git: not found", 127}
          git -> ReleaseEnv.cmd(git, ["-C", repo | args], stderr_to_stdout: true)
        end
      end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"git timed out after #{@git_timeout_ms} ms", 124}
    end
  end

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp tail(text) when is_binary(text), do: text |> String.trim() |> String.slice(-1500, 1500)
  defp tail(other), do: inspect(other)

  # A compiled tree can hold read-only files; make it writable first.
  defp force_rm_rf(path) do
    if File.exists?(path) do
      _ = ReleaseEnv.cmd("chmod", ["-R", "u+rwX", path], stderr_to_stdout: true)
      File.rm_rf(path)
    end

    :ok
  end
end
