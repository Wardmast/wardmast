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

  `<root>/<lock12>-<toolchain12>[-<mix_env>]` (`root` default `<scratch_root>/capture-deps`): the lock's
  SHA-256, and a fingerprint of the toolchain the boot will use (Elixir, OTP, ERTS and the
  architecture, as `elixir` reports them **inside the capture sandbox**, so it is the one the
  boots run), and the `MIX_ENV` it was compiled under unless that is `dev` (bd-ur1zty). Hex and rebar3 archives and precompiled NIFs are bound to that toolchain, so a new
  one misses the cache. The seed and that probe run with the boot's `env.PATH` when it pins a
  toolchain (only system dirs and `readonly_paths` entries kept; bd-2qj1ry), else the server's. A miss seeds it, once per key (`:global.trans/4`):

    1. `git archive` of the source commit (no `.git`, nothing a worker wrote);
    2. `seed_script/0` in it, through the sandbox's `fetch_command/2`: the same filesystem
       allowlist as a boot (its `readonly_paths` too) **with the network on**, an environment
       built from nothing (plus the server's own proxy variables, never one with a credential in
       it) and the values the repo's screenshots config wrote (`input.seed_env`, from
       `Config.deps_seed/1`: `deps.env` over the boot's literal `env`; never the server's own
       environment, and never the names this module sets itself), `MIX_ENV=<input.mix_env>`
       (`deps.mix_env`, else the boot's `MIX_ENV`, else `dev`: a strict `config/runtime.exs` that
       raises without `DATABASE_URL` seeds when the config provides it):
       `mix local.hex`/`local.rebar` (when the lock needs them), `mix deps.get`, `mix
       deps.compile` (which also downloads precompiled NIFs, `elixir_make` and
       `rustler_precompiled`, into the cache), then `mix esbuild.install`/`tailwind.install`
       when the deps include them;
    3. the results (`deps/`, `mix/`, `hex/`, `cache/`, `bin/esbuild-*`, `bin/tailwind-*`) are
       published by an atomic rename with a `.complete` stamp. A failed seed leaves nothing. A
       seed killed with its capture (a newer head cancels it, a shutdown) cannot clean up: its
       `seed-<key>-*` work is swept by the next seed of that cache, under the same lock, and any
       left longer than `keep_days` goes with the prune.

  The seed's compiled dependencies (`_build/<env>/`) are kept as `build/` (bd-8udsgf); the rest
  of its `_build` is discarded.

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
  config looks for it.

  The cache stays read-only and is never written by a boot. A dependency that writes into its
  own source directory while compiling (phoenix copies templates into `priv/`) would fail on it,
  so `writable/3` gives each boot a copy: `deps/` to `<scratch>/deps` (`MIX_DEPS_PATH` points
  there; `cp -a --reflink=auto`) and `build/<env>` to `<checkout>/_build/<env>`. Dependencies
  the seed already compiled are not compiled again; one that does compile writes into the copy.
  The precompiled NIFs the seed fetched keep `exqlite`, `mdex` and the like working.

  ## Options

  `:root`, `:seed_script` and `:seed_env` (`[{name, value}]` added to the seed's environment;
  tests), `:keep_days` (completed caches unused that long, and a killed run's work that old, are
  pruned after a seed; default 14).
  """

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Sandbox
  alias Wardmast.Worker.ReleaseEnv
  alias Wardmast.Worker.Worktree

  require Logger

  @complete ".complete"
  @fingerprint_timeout_ms 60_000
  @git_timeout_ms 120_000
  @proxy_env ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)
  @keep_days 14
  @system_dirs ~w(/usr /bin /sbin /lib /lib64 /opt)
  # What the seed sets itself: a config value for one of these is dropped, not applied.
  @host_env ~w(PATH HOME LANG TMPDIR MIX_ENV ARB_NEED_HEX ARB_NEED_REBAR MIX_DEPS_PATH MIX_HOME
               HEX_HOME HEX_OFFLINE ELIXIR_MAKE_CACHE_DIR RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
               MIX_ESBUILD_PATH MIX_TAILWIND_PATH) ++ @proxy_env
  # What the seed produces that boots are pointed at (`bin/` is the host's own).
  @adopted ~w(deps mix hex cache)

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
          deps: String.t(),
          build: String.t(),
          env: [{String.t(), String.t()}],
          links: [{String.t(), String.t()}]
        }

  @doc "What the seed runs in the source tree (for the docs and tests)."
  @spec seed_script() :: String.t()
  def seed_script, do: @seed_script

  # ── plan ────────────────────────────────────────────────────────────────

  @doc """
  The trusted lockfile for a capture of `base..head` in `repo`: `{:ok, %{source:, lock_hash:,
  lock:, repo:}}` (the commit to seed from, in the server-owned repository `repo`), `{:ok, :none}`
  (no `mix.lock` at either commit), `{:skip, reason}` (the head's lockfile is not one the default
  branch vouches for) or `{:error, message}`. Options: `:root`.

  Nothing in `repo` (the worker's checkout) is trusted: its refs and objects are writable from the
  worker's jail. The default branch's tip is read live from origin (`git ls-remote`, whose URL is
  in the repository config the jail keeps read-only) and taken into a repository under `:root`
  that only the server writes, through the pack protocol, which names every object by the hash
  of its own content (so an object forged in the worker's store cannot pass for it). The source
  is the merge-base when that repository shows it on the default branch, else the tip itself.
  """
  @spec plan(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           :none
           | %{source: String.t(), lock_hash: String.t(), lock: binary(), repo: String.t()}}
          | {:skip, String.t()}
          | {:error, String.t()}
  def plan(repo, base, head, default_branch, opts \\ []) do
    base_lock = lock_at(repo, base)

    case {base_lock, lock_at(repo, head)} do
      {:none, :none} ->
        {:ok, :none}

      {_, :none} ->
        {:skip, changed("deletes mix.lock")}

      {_, {:ok, head_lock}} ->
        trusted_source(repo, base, base_lock, head_lock, default_branch, opts)
    end
  end

  defp changed(what) do
    "the change #{what}; a capture boot has no network and only gets dependencies fetched from " <>
      "a lockfile the default branch has had, so it cannot boot this change (its own mix.exs " <>
      "and lockfile never run with a network)"
  end

  # bd-5eegxz: the head's lockfile is judged against the default branch, never against the
  # merge-base alone. A branch that merged main after main bumped its lockfile has a (stale)
  # merge-base with the older lock, yet carries exactly main's current one: not a lockfile edit.
  defp trusted_source(repo, base, base_lock, head_lock, branch, opts) do
    with {:ok, tip} <- live_tip(repo, branch),
         {:ok, trusted} <- trusted_repo(repo, tip, branch, opts) do
      # The worker's copy of the base's lockfile is only a hint; what counts is the trusted one.
      on_branch? = ancestor?(trusted, base, tip)
      candidates = if on_branch?, do: Enum.uniq([base, tip]), else: [tip]

      case Enum.find(candidates, &(lock_at(trusted, &1) == {:ok, head_lock})) do
        nil ->
          {:skip, not_trusted(base_lock, on_branch?, branch)}

        source ->
          {:ok, %{source: source, lock_hash: digest(head_lock), lock: head_lock, repo: trusted}}
      end
    end
  end

  defp not_trusted(:none, _on_branch?, _branch), do: changed("adds a mix.lock")
  defp not_trusted(_base_lock, true, _branch), do: changed("edits mix.lock")

  defp not_trusted(_base_lock, false, branch) do
    "this change's mix.lock is not one the default branch (#{branch}) has: its merge-base " <>
      "is not on #{branch} and #{branch}'s own lockfile differs. A capture boot only gets " <>
      "dependencies fetched from a default-branch lockfile"
  end

  defp live_tip(repo, branch) do
    case Worktree.remote_head(repo, branch) do
      sha when is_binary(sha) ->
        {:ok, sha}

      nil ->
        {:error,
         "cannot read the default branch #{inspect(branch)} from origin (git ls-remote) to " <>
           "check the lockfile against; the deps cache trusts origin, never a local ref"}
    end
  end

  # `<root>/repos/<common dir hash>.git`, a bare repository only the server writes, holding the
  # default branch's history as fetched (and hashed) from the checkout's object store.
  defp trusted_repo(repo, tip, branch, opts) do
    with {:ok, common} <- common_dir(repo) do
      trusted =
        Path.join([root(opts), "repos", binary_part(digest(common), 0, 16) <> ".git"])

      :global.trans({{__MODULE__, trusted}, self()}, fn ->
        with :ok <- init_bare(trusted),
             :ok <- take_tip(trusted, repo, common, tip, branch),
             do: {:ok, trusted}
      end)
    end
  end

  # `tip` into the trusted repository from the checkout's object store. The checkout may not have
  # it yet (origin moved since its last fetch): one fetch from origin into it, then a second try.
  defp take_tip(trusted, repo, common, tip, branch) do
    case verified_fetch(trusted, common, tip) do
      :ok ->
        :ok

      {:error, _} ->
        _ = git(repo, ["fetch", "--quiet", "--no-tags", "origin", "refs/heads/" <> branch])
        verified_fetch(trusted, common, tip)
    end
  end

  defp common_dir(repo) do
    case git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "#{repo} is not a git checkout: #{tail(out)}"}
    end
  end

  defp init_bare(dir) do
    if File.dir?(Path.join(dir, "objects")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(dir))

      case git(Path.dirname(dir), ["init", "--quiet", "--bare", dir]) do
        {_, 0} -> :ok
        {out, _} -> {:error, "could not create the trusted repository #{dir}: #{tail(out)}"}
      end
    end
  end

  # Fetching through the pack protocol re-hashes every object it receives, and fsck checks them.
  defp verified_fetch(trusted, common, tip) do
    args = [
      "-c",
      "transfer.fsckObjects=true",
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      "--upload-pack=git -c uploadpack.allowAnySHA1InWant=true upload-pack",
      "file://" <> common,
      "+" <> tip <> ":refs/heads/trusted"
    ]

    case git(trusted, args) do
      {_, 0} ->
        :ok

      {out, _} ->
        {:error,
         "could not take the default branch's head #{String.slice(tip, 0, 12)} into the trusted " <>
           "repository: #{tail(out)}"}
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
           plan(input.repo_path, input.base_sha, input.head_sha, input.default_branch, opts),
         root = root(opts),
         :ok <- mkdir(root),
         {:ok, toolchain} <- fingerprint(input, source, root) do
      dir =
        Path.join(
          root,
          binary_part(source.lock_hash, 0, 12) <> "-" <> toolchain <> env_suffix(mix_env(input))
        )

      with :ok <- ensure(dir, input, source, opts) do
        {:ok, cache(dir)}
      end
    else
      {:ok, :none} -> {:ok, nil}
      other -> other
    end
  end

  # bd-ur1zty: the cache is built under the MIX_ENV the boot uses (`input.mix_env`, default
  # "dev"): `mix deps.compile` builds, and downloads the precompiled NIFs of, only the deps that
  # env uses, so a `dev` cache has no `only: :test` dep a `MIX_ENV=test` boot needs. "dev" keeps
  # the key it always had (an existing cache stays valid); any other env is part of it.
  defp env_suffix("dev"), do: ""
  defp env_suffix(mix_env), do: "-" <> mix_env

  defp mix_env(input) do
    case Map.get(input, :mix_env) do
      env when is_binary(env) and env != "" -> env
      _ -> "dev"
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

      case git(source.repo, ["cat-file", "blob", source.source <> ":.tool-versions"]) do
        {versions, 0} -> File.write!(Path.join(probe, ".tool-versions"), versions)
        _ -> :ok
      end

      box = %{checkout: probe, scratch: probe, readonly_paths: input.readonly_paths}
      env = [{"PATH", toolchain_path(input)}, {"HOME", home}, {"LANG", "C.UTF-8"}]
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
    # Named for its cache, so the next seed of that cache can tell its leftovers.
    work = Path.join(Path.dirname(dir), seed_prefix(dir) <> token())
    src = Path.join(work, "src")
    scratch = Path.join(work, "scratch")
    out = Path.join(scratch, "out")
    # The host's own: never shown to the seed, which can only have written `src` and `scratch`.
    staging = Path.join(work, "staging")

    try do
      Enum.each(
        [src, Path.join(scratch, "home"), Path.join(scratch, "tmp"), out, staging],
        &File.mkdir_p!/1
      )

      with :ok <- export(source.repo, source.source, work, src),
           :ok <- run_seed(input, source, src, scratch, out, opts),
           :ok <- adopt(out, staging),
           :ok <- collect_tools(src, staging),
           :ok <- collect_build(src, staging),
           :ok <- publish(staging, dir, source) do
        Logger.info("Capture.DepsCache: seeded #{dir} from #{String.slice(source.source, 0, 12)}")
        prune(Path.dirname(dir), dir, Keyword.get(opts, :keep_days, @keep_days))
        :ok
      end
    after
      force_rm_rf(work)
      clear_leftovers(dir)
    end
  end

  defp seed_prefix(dir), do: "seed-" <> Path.basename(dir) <> "-"

  # A seed's `after` does not run when its capture is killed (a newer head cancels it, bd-8qj1sa;
  # a shutdown stops it), so its work stays. This runs under `dir`'s lock, which a killed seed
  # released when it died: every other `seed-<key>-*` is one of those. Swept once this seed has
  # run, by when the killed one's processes (stopped with their owner, `AppProcess`) are gone.
  defp clear_leftovers(dir) do
    root = Path.dirname(dir)
    prefix = seed_prefix(dir)

    case File.ls(root) do
      {:ok, entries} ->
        for entry <- entries,
            String.starts_with?(entry, prefix),
            do: force_rm_rf(Path.join(root, entry))

        :ok

      {:error, _} ->
        :ok
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
        {"PATH", toolchain_path(input)},
        {"HOME", Path.join(scratch, "home")},
        {"LANG", "C.UTF-8"},
        {"TMPDIR", Path.join(scratch, "tmp")},
        {"MIX_ENV", mix_env(input)},
        {"ARB_NEED_HEX", flag(source.lock =~ "{:hex,")},
        {"ARB_NEED_REBAR", flag(source.lock =~ ":rebar3")}
      ] ++
        proxy_env() ++
        seed_paths(out) ++ config_env(input) ++ Keyword.get(opts, :seed_env, [])

    timeout = Map.get(input, :timeout_s, 600) * 1000

    case sandboxed(&input.sandbox.fetch_command(&1, &2), ["sh", "-c", script], box, env, timeout) do
      {:ok, _} ->
        :ok

      {:error, detail} ->
        {:error, "fetching the Mix deps for the capture failed: #{tail(detail)}"}
    end
  end

  # bd-ur1zty: the values the repo's screenshots config wrote for the seed (`input.seed_env`,
  # `Config.deps_seed_env/1`), so an app whose `config/runtime.exs` raises without them (a
  # `DATABASE_URL`, a `SECRET_KEY_BASE`) can still compile. Only those: the seed's environment is
  # otherwise built from nothing, so no operator secret reaches it. The host's own names above
  # (paths, `MIX_ENV`, the proxy) are not the config's to repoint.
  defp config_env(input) do
    for {name, value} <- Map.get(input, :seed_env, []),
        is_binary(name) and is_binary(value),
        name not in @host_env,
        do: {name, value}
  end

  # bd-2qj1ry: the seed (and the fingerprint keying its cache) runs on the toolchain the boot
  # does. A boot whose `env.PATH` pins one (mise/asdf install dirs) gets that PATH here too, so
  # Mix's `$MIX_HOME/elixir/<elixir>-otp-<otp>/` (rebar3, the Hex archive) is the boot's. Only
  # directories the boot could see are kept: absolute, no `..`, under a system dir or one of
  # `readonly_paths`; anything else is dropped. No pin (or nothing left of it) is the server's.
  defp toolchain_path(input) do
    {path, _dropped} =
      toolchain_path(Map.get(input, :readonly_paths, []), Map.get(input, :seed_env, []))

    path
  end

  @doc """
  The seed/probe PATH for a pinned `env.PATH` and `readonly_paths` (`~` expanded the way the bwrap
  mounts are): `{path, dropped}`, `dropped` being the pinned entries the filter removed.
  """
  @spec toolchain_path([term()], [{String.t(), String.t()}]) :: {String.t(), [String.t()]}
  def toolchain_path(readonly_paths, seed_env) do
    pinned =
      Enum.find_value(seed_env, fn
        {"PATH", value} when is_binary(value) -> value
        _ -> nil
      end)

    allowed =
      @system_dirs ++ Enum.map(readonly_paths, fn p -> p |> to_string() |> Path.expand() end)

    entries = String.split(pinned || "", ":", trim: true)

    {kept, dropped} =
      Enum.split_with(entries, fn dir ->
        Path.type(dir) == :absolute and ".." not in Path.split(dir) and
          Enum.any?(allowed, &under?(dir, &1))
      end)

    path = if kept == [], do: Sandbox.path(), else: Enum.join(kept, ":")
    {path, dropped}
  end

  @doc "The note naming dropped pinned PATH entries, or `nil` when none were."
  @spec path_warning([String.t()]) :: String.t() | nil
  def path_warning([]), do: nil

  def path_warning(dropped) do
    "pinned PATH entries outside system dirs and readonly_paths were dropped: " <>
      Enum.join(dropped, ", ")
  end

  defp under?(dir, root) do
    root = String.trim_trailing(root, "/")
    root != "" and (dir == root or String.starts_with?(dir, root <> "/"))
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

  # What the seed leaves is untrusted to the host (a default-branch dependency can be malicious):
  # its directories are moved whole into the host's staging dir, only when they are real
  # directories, and the host never writes into them or follows a link it planted.
  defp adopt(out, staging) do
    Enum.reduce_while(@adopted, :ok, fn name, :ok ->
      from = Path.join(out, name)
      to = Path.join(staging, name)

      case File.lstat(from) do
        {:ok, %File.Stat{type: :directory}} ->
          case File.rename(from, to) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, adopt_error(name, reason)}}
          end

        {:error, :enoent} ->
          File.mkdir!(to)
          {:cont, :ok}

        {:ok, %File.Stat{type: type}} ->
          {:halt,
           {:error,
            "the deps seed left #{name} as a #{type}, not a directory; nothing was published"}}

        {:error, reason} ->
          {:halt, {:error, adopt_error(name, reason)}}
      end
    end)
  end

  defp adopt_error(name, reason),
    do: "could not keep the deps seed's #{name}: #{:file.format_error(reason)}"

  # `mix esbuild.install` / `tailwind.install` put their binary next to `_build/<env>`: copied only
  # when `_build` is a real directory and the binary a regular file (never through a link).
  defp collect_tools(src, staging) do
    bin = Path.join(staging, "bin")
    File.mkdir!(bin)
    build = Path.join(src, "_build")

    if match?({:ok, %File.Stat{type: :directory}}, File.lstat(build)) do
      for file <- Path.wildcard(Path.join(build, "{esbuild,tailwind}-*")),
          match?({:ok, %File.Stat{type: :regular}}, File.lstat(file)) do
        dest = Path.join(bin, Path.basename(file))
        File.cp!(file, dest)
        File.chmod!(dest, 0o755)
      end
    end

    :ok
  rescue
    e in File.Error -> {:error, "could not keep the asset tools: #{Exception.message(e)}"}
  end

  # bd-8udsgf: the seed's compiled dependencies (`_build/<env>/`), kept as `build/`, which a boot
  # copies into its own checkout's `_build` so it does not recompile them. Only real directories
  # are moved (never through a link the seed planted); the tools' files are `collect_tools`'s.
  defp collect_build(src, staging) do
    build = Path.join(src, "_build")
    kept = Path.join(staging, "build")
    File.mkdir!(kept)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(build),
         {:ok, entries} <- File.ls(build) do
      for entry <- entries,
          from = Path.join(build, entry),
          match?({:ok, %File.Stat{type: :directory}}, File.lstat(from)),
          do: File.rename!(from, Path.join(kept, entry))
    end

    :ok
  rescue
    e in File.Error -> {:error, "could not keep the compiled deps: #{Exception.message(e)}"}
  end

  # The stamp goes into the host's staging dir, then the atomic rename: the final name only ever
  # appears complete.
  defp publish(staging, dir, source) do
    File.write!(
      Path.join(staging, @complete),
      "lock=#{source.lock_hash}\nsource=#{source.source}\n"
    )

    case File.rename(staging, dir) do
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

  # Completed caches nobody used for `days` (another lockfile, an old toolchain), and work a killed
  # run left that long ago (`clear_leftovers/1` only sweeps the cache it seeds; a `probe-*` takes
  # no lock): no seed or probe runs for days. Never `keep`.
  defp prune(root, keep, days) do
    cutoff = System.os_time(:second) - days * 86_400

    for entry <- File.ls!(root),
        path = Path.join(root, entry),
        path != keep,
        prunable?(entry, path, cutoff) do
      force_rm_rf(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp prunable?(entry, path, cutoff) do
    cond do
      Regex.match?(~r/\A[0-9a-f]{12}-[0-9a-f]{12}\z/, entry) ->
        stale?(Path.join(path, @complete), cutoff)

      String.starts_with?(entry, ["seed-", "probe-"]) ->
        stale?(path, cutoff)

      true ->
        false
    end
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
      deps: Path.join(dir, "deps"),
      build: Path.join(dir, "build"),
      links: Enum.map(tools, &{Path.join("_build", &1), Path.join([dir, "bin", &1])})
    }
  end

  defp tool_env(tools, prefix, var, dir) do
    case Enum.find(tools, &String.starts_with?(&1, prefix)) do
      nil -> []
      tool -> [{var, Path.join([dir, "bin", tool])}]
    end
  end

  # ── the boot's writable view ────────────────────────────────────────────

  @doc """
  Makes the cache usable by one boot without ever writing to it (bd-8udsgf): `deps/` is copied
  (`cp -a --reflink=auto`, copy-on-write where the filesystem has it) to `<scratch>/deps`, and
  the seed's compiled `build/<env>` into `<checkout>/_build/<env>`, so a dependency that writes
  into its own source directory while compiling (phoenix copies templates into `priv/`) writes
  into the copy, and deps the seed compiled are not compiled again. Returns the environment
  overrides for the boot (`MIX_DEPS_PATH` at the copy). The cache itself is only read.
  """
  @spec writable(cache(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def writable(cache, scratch, checkout) do
    deps = Path.join(scratch, "deps")

    build = Path.join(checkout, "_build")

    with :ok <- copy_tree(cache.deps, deps),
         :ok <- copy_build(cache.build, build),
         :ok <- relink_priv(build, deps) do
      {:ok, [{"MIX_DEPS_PATH", deps}]}
    end
  end

  # Mix links `_build/<env>/lib/<dep>/priv` to the dependency's source `priv` with a relative
  # link, which the seed's layout wrote and the boot's does not share. Re-point every one at the
  # boot's deps copy (never following the seed's target); drop it when the dep has no `priv`.
  defp relink_priv(build, deps) do
    for env <- ls_dirs(build),
        dep <- ls_dirs(Path.join([build, env, "lib"])) do
      link = Path.join([build, env, "lib", dep, "priv"])

      case File.lstat(link) do
        {:ok, %File.Stat{type: :symlink}} ->
          File.rm(link)
          source = Path.join([deps, dep, "priv"])
          if File.dir?(source), do: File.ln_s(source, link)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp ls_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp copy_build(from, to) do
    case File.lstat(from) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- safe_build_dir(to),
             :ok <- File.mkdir_p(to),
             {:ok, entries} <- File.ls(from) do
          copy_entries(entries, from, to)
        else
          {:error, {:unsafe, why}} -> {:error, copy_error(from, why)}
          {:error, reason} -> {:error, copy_error(from, :file.format_error(reason))}
        end

      _ ->
        # A cache from before the seed kept its build: the boot compiles its deps.
        :ok
    end
  end

  defp copy_entries(entries, from, to) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case copy_tree(Path.join(from, entry), Path.join(to, entry)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The checkout is the worker's tree: a `_build` it committed as a link is never written through.
  defp safe_build_dir(to) do
    case File.lstat(to) do
      {:ok, %File.Stat{type: type}} when type != :directory ->
        {:error, {:unsafe, "#{to} is a #{type}, not a directory"}}

      _ ->
        :ok
    end
  end

  defp copy_tree(from, to) do
    File.rm_rf!(to)

    with :ok <- File.mkdir_p(Path.dirname(to)),
         {_, 0} <-
           ReleaseEnv.cmd("cp", ["-a", "--reflink=auto", "--", from, to], stderr_to_stdout: true),
         {_, 0} <- ReleaseEnv.cmd("chmod", ["-R", "u+rwX", "--", to], stderr_to_stdout: true) do
      :ok
    else
      {:error, reason} -> {:error, copy_error(from, :file.format_error(reason))}
      {output, _} -> {:error, copy_error(from, tail(output))}
    end
  end

  defp copy_error(from, reason),
    do: "could not copy the deps cache's #{from} for the boot: #{reason}"

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
