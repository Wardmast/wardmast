defmodule Wardmast.Screenshots.Config do
  @moduledoc """
  The `worker.repos.<repo>.screenshots` block (design: `docs/design/ui-screenshot-capture.md` §6, D4).

  Resolves like `Wardmast.Preview.Config`: `worker.repos.<repo>.screenshots` is deep-merged over
  `worker.screenshots` (repo keys win; `env`, `viewports`, `themes`, `seeds`, `limits` merge by key).
  `start_cmd`, `setup_cmd` and `ready` fall back to `preview.command`, `preview.setup` and
  `preview.ready_path` / `preview.ready_timeout` when unset. Nothing set, or `enabled: false`,
  means the feature is off (`:none`). Every key is documented in
  `Wardmast.Tasks.Workspace.ConfigSchema`.

  `touches_ui_paths?/2` answers "does this diff touch `ui_paths`?" for the capture pass and the
  ReviewGate; `diff_touches_ui_paths?/4` runs it over a git diff.
  """

  alias Wardmast.Preview.Config, as: PreviewConfig
  alias Wardmast.Worker.SeedPaths
  alias Wardmast.Worker.SpawnEnv
  alias Wardmast.Worker.VisualBaselines.Drift

  @keys ~w(enabled ui_paths ignore_paths plan_required default_routes start_cmd setup_cmd seed_cmd
           seeds port_env port_range base_url env ready login viewports default_viewports themes
           default_themes fixture_check deny_patterns fixture_email_domains limits hosting attach
           sandbox services deps)
  @placeholders ~w(port role scratch checkout task_id)
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @proxy_keys ~w(HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)
  @loopback ~w(127.0.0.1 localhost)
  @name ~r/\A[a-z0-9-]{1,20}\z/
  @worker_range {20_000, 29_999}
  @max_memory_gib 16

  @default_viewports %{
    "desktop" => %{"width" => 1280, "height" => 800, "device_scale_factor" => 1},
    "mobile" => %{"width" => 390, "height" => 844, "device_scale_factor" => 2}
  }
  @default_themes %{
    "light" => %{"color_scheme" => "light"},
    "dark" => %{"color_scheme" => "dark", "local_storage" => %{"theme" => "dark"}, "query" => %{}}
  }
  @default_limits %{
    "max_shots" => 20,
    "max_images" => 40,
    "max_image_bytes" => 2_097_152,
    "max_capture_bytes" => 25_165_824,
    "setup_seconds" => 600,
    "seed_seconds" => 120,
    "shot_seconds" => 30,
    "budget_seconds" => 1200,
    "memory" => "4g",
    "cpus" => 2,
    "max_captures_per_ticket" => 3
  }
  # Limits that were once documented and did nothing. Still accepted in a stored block (so a
  # workspace that set one keeps validating) and dropped when the config is built.
  # `merge_wait_seconds` (bd-8qj1sa): capture finishes in the ReviewGate, before a reviewer and
  # long before merge, so there is nothing at merge time to wait for.
  @retired_limits ~w(merge_wait_seconds)
  @limit_max %{"budget_seconds" => 3600, "cpus" => 16}
  @default_hosting %{
    "github" => %{"mode" => "assets_branch", "branch" => "arbiter-assets"},
    "public_repo_ok" => false,
    "retention_days" => 90
  }
  @default_emails ~w(example.com example.org example.net test invalid localhost)
  @default_sandbox %{"readonly_paths" => []}
  @default_deps %{"mix" => false}

  # bd-3glf2a: `services` (per-boot containers bridged into the sandbox) and `deps` (the offline
  # Mix deps cache).
  @service_name ~r/\A[a-z][a-z0-9-]{0,15}\z/
  @service_keys ~w(image port env command ready socket)
  @image_ref ~r/\A[^\s\x00-][^\s\x00]{0,254}\z/
  @service_socket ~r{\A/(run|tmp)/[A-Za-z0-9._/-]+\z}
  @max_socket_bytes 100
  @service_ready_default_s 60
  @service_ready_max_s 600
  @mix_env ~r/\A[a-z][a-z0-9_]{0,31}\z/
  # What the seed sets itself (`Capture.DepsCache`): a `deps.env` value for one would be dropped.
  @seed_reserved ~w(PATH HOME LANG TMPDIR MIX_ENV ARB_NEED_HEX ARB_NEED_REBAR)
  @deps_env ~w(MIX_DEPS_PATH MIX_HOME HEX_HOME HEX_OFFLINE MIX_ESBUILD_PATH MIX_TAILWIND_PATH
               ELIXIR_MAKE_CACHE_DIR RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH)

  defstruct ui_paths: [],
            ignore_paths: [],
            plan_required: true,
            default_routes: [],
            start_cmd: nil,
            setup_cmd: nil,
            seed_cmd: nil,
            seeds: %{},
            port_env: "PORT",
            port_range: {32_000, 32_999},
            base_url: "http://127.0.0.1:{{port}}",
            env: %{},
            ready: %{"path" => "/", "timeout_seconds" => 120, "expect" => "below_500"},
            login: %{"kind" => "none"},
            viewports: @default_viewports,
            default_viewports: ["desktop"],
            themes: @default_themes,
            default_themes: ["light"],
            fixture_check: nil,
            deny_patterns: [],
            fixture_email_domains: @default_emails,
            limits: @default_limits,
            hosting: @default_hosting,
            attach: true,
            sandbox: @default_sandbox,
            services: [],
            deps: @default_deps

  @typedoc "One `services` entry as resolved (sorted by name; `ready` defaults to `tcp`)."
  @type service :: %{
          name: String.t(),
          image: String.t(),
          port: 1024..65_535,
          env: [{String.t(), String.t()}],
          command: [String.t()],
          ready:
            %{kind: :tcp, timeout_seconds: pos_integer()}
            | %{kind: :cmd, cmd: [String.t()], timeout_seconds: pos_integer()},
          socket: String.t() | nil
        }

  @type t :: %__MODULE__{}

  @doc """
  What the operator should know about the data safety of each repo that has an effective
  `screenshots` config (design §9.4, bd-995svb): `[%{repo:, fixture_check: boolean, warnings: [String.t()]}]`
  sorted by repo. A repo with no `fixture_check` is flagged: it relies on structural isolation
  alone, with nothing probing that the booted app is on fixture data. Shown by the config overview.
  """
  @spec safety_overview(term()) :: [map()]
  def safety_overview(%{config: %{"worker" => %{"repos" => %{} = repos}}} = workspace) do
    for repo <- repos |> Map.keys() |> Enum.sort(),
        {:ok, config} <- [resolve(workspace, repo)] do
      checked? = config.fixture_check != nil

      %{
        repo: repo,
        fixture_check: checked?,
        warnings:
          if(checked?,
            do: [],
            else: [
              "no fixture_check: nothing verifies that the app boots on fixture data, so this " <>
                "repo relies on capture isolation alone. Set screenshots.fixture_check.marker " <>
                "(an endpoint that says the app runs on fixture data)."
            ]
          )
      }
    end
  end

  def safety_overview(_workspace), do: []

  @doc """
  Whether `fixture_check.marker` is checked inside the shooter's logged-in browser session (after
  `login` and `login.post_login_path`, before the shot) rather than by the anonymous
  `Capture.Safety.probe_marker/3`: when there is a `fixture_check`, a `login` other than
  `"none"`, and the marker does not opt out with `"auth": false`. A marker path behind the login
  can never pass an anonymous request (it is redirected to sign-in).
  """
  @spec marker_in_session?(t()) :: boolean()
  def marker_in_session?(%__MODULE__{fixture_check: %{"marker" => %{} = marker}, login: login}) do
    Map.get(marker, "auth") != false and login_kind(login) not in [nil, "none"]
  end

  def marker_in_session?(_config), do: false

  defp login_kind(%{"kind" => kind}), do: kind
  defp login_kind(_login), do: nil

  @doc "The keys a `screenshots` block may carry."

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  The effective config for `repo` in `workspace`: `:none` when unset or disabled, `{:ok, config}`,
  or `{:error, [message]}` for a block that does not validate (a hand-edited row).
  """
  @spec resolve(term(), String.t() | nil) :: {:ok, t()} | :none | {:error, [String.t()]}
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    case SeedPaths.effective(worker, repo) do
      %{"screenshots" => %{} = block} -> resolve_block(block, worker)
      _ -> :none
    end
  end

  def resolve(_workspace, _repo), do: :none

  defp resolve_block(block, worker) do
    merged = inherit_preview(block, Map.get(worker, "preview"), worker)

    case validate(merged, "screenshots") do
      [] -> if Map.get(merged, "enabled", true) == false, do: :none, else: {:ok, build(merged)}
      errors -> {:error, errors}
    end
  end

  # `preview` per repo is already merged into `worker` by `SeedPaths.effective/2`.
  defp inherit_preview(block, preview, _worker) when is_map(preview) do
    block
    |> put_new("start_cmd", preview["command"])
    |> put_new("setup_cmd", preview["setup"])
    |> inherit_ready(preview)
  end

  defp inherit_preview(block, _preview, _worker), do: block

  defp inherit_ready(block, preview) do
    from_preview =
      %{"path" => preview["ready_path"], "timeout_seconds" => preview["ready_timeout"]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Map.get(block, "ready") do
      %{} = ready -> Map.put(block, "ready", Map.merge(from_preview, ready))
      nil when from_preview != %{} -> Map.put(block, "ready", from_preview)
      _ -> block
    end
  end

  defp put_new(block, _key, nil), do: block
  defp put_new(block, key, value), do: Map.put_new(block, key, value)

  defp build(block) do
    d = %__MODULE__{}
    {:ok, range} = parse_range(Map.get(block, "port_range", "32000-32999"))

    %__MODULE__{
      ui_paths: block["ui_paths"],
      ignore_paths: Map.get(block, "ignore_paths", []),
      plan_required: Map.get(block, "plan_required", true),
      default_routes: Map.get(block, "default_routes", []),
      start_cmd: block["start_cmd"],
      setup_cmd: block["setup_cmd"],
      seed_cmd: block["seed_cmd"],
      seeds: Map.get(block, "seeds", %{}),
      port_env: Map.get(block, "port_env", d.port_env),
      port_range: range,
      base_url: Map.get(block, "base_url", d.base_url),
      env: Map.get(block, "env", %{}),
      ready: Map.merge(d.ready, Map.get(block, "ready", %{})),
      login: Map.get(block, "login", d.login),
      viewports: Map.get(block, "viewports", %{}) |> then(&Map.merge(d.viewports, &1)),
      default_viewports: Map.get(block, "default_viewports", d.default_viewports),
      themes: Map.get(block, "themes", %{}) |> then(&Map.merge(d.themes, &1)),
      default_themes: Map.get(block, "default_themes", d.default_themes),
      fixture_check: block["fixture_check"],
      deny_patterns: Map.get(block, "deny_patterns", []),
      fixture_email_domains: Map.get(block, "fixture_email_domains", d.fixture_email_domains),
      limits: Map.merge(d.limits, Map.drop(Map.get(block, "limits", %{}), @retired_limits)),
      hosting: Map.merge(d.hosting, Map.get(block, "hosting", %{})),
      attach: Map.get(block, "attach", true),
      sandbox: Map.merge(d.sandbox, Map.get(block, "sandbox", %{})),
      services: block |> Map.get("services", %{}) |> build_services(),
      deps: Map.merge(d.deps, Map.get(block, "deps", %{}))
    }
  end

  # Sorted by name, so a boot starts (and the sandbox relays) them in a stable order.
  defp build_services(services) do
    services
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, s} ->
      %{
        name: name,
        image: s["image"],
        port: s["port"],
        env: s |> Map.get("env", %{}) |> Enum.sort(),
        command: Map.get(s, "command", []),
        ready: build_ready(Map.get(s, "ready", %{"tcp" => true})),
        socket: s["socket"]
      }
    end)
  end

  defp build_ready(%{"cmd" => cmd} = ready) do
    %{
      kind: :cmd,
      cmd: cmd,
      timeout_seconds: Map.get(ready, "timeout_seconds", @service_ready_default_s)
    }
  end

  defp build_ready(ready),
    do: %{
      kind: :tcp,
      timeout_seconds: Map.get(ready, "timeout_seconds", @service_ready_default_s)
    }

  @doc "The variables the offline deps cache (`deps.mix`) sets in every boot's environment."
  @spec deps_env_names() :: [String.t()]
  def deps_env_names, do: @deps_env

  # ── ui_paths matching ───────────────────────────────────────────────────

  @doc "Does `file` (repo-relative) match `ui_paths` and not `ignore_paths`?"
  @spec matches_ui_path?(t(), String.t()) :: boolean()
  def matches_ui_path?(%__MODULE__{} = config, file) when is_binary(file) do
    Enum.any?(config.ui_paths, &Drift.glob_match?(&1, file)) and
      not Enum.any?(config.ignore_paths, &Drift.glob_match?(&1, file))
  end

  @doc "Does any of the changed `files` match `ui_paths` (and not `ignore_paths`)?"
  @spec touches_ui_paths?(t(), [String.t()]) :: boolean()
  def touches_ui_paths?(%__MODULE__{} = config, files) when is_list(files),
    do: Enum.any?(files, &matches_ui_path?(config, &1))

  @doc """
  Does the diff `base..head` in `checkout` touch `ui_paths`? `{:error, reason}` when git fails.
  Pass the merge-base as `base`.
  """
  @spec diff_touches_ui_paths?(t(), String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, String.t()}
  def diff_touches_ui_paths?(%__MODULE__{} = config, checkout, base, head) do
    case Drift.git(checkout, ["diff", "--name-only", "--no-renames", base, head]) do
      {:ok, out} -> {:ok, touches_ui_paths?(config, String.split(out, "\n", trim: true))}
      {:error, _} = err -> err
    end
  end

  # ── validation ──────────────────────────────────────────────────────────

  @doc """
  Validate a merged `screenshots` block, returning error messages (`[]` = valid). `label` is the
  config path, e.g. `"worker.repos.app.screenshots"`. `start_cmd` is required here: callers that
  allow inheritance from `preview` pass the block through `resolve/2`, or use `validate_partial/2`.
  """
  @spec validate(term(), String.t()) :: [String.t()]
  def validate(%{} = block, label) do
    unknown_errors(block, label) ++
      required_errors(block, label) ++
      key_errors(block, label) ++ service_range_errors(block, label)
  end

  def validate(_block, label), do: ["#{label} must be a map"]

  @doc """
  Validate a block as written (before merging or preview inheritance): the same checks minus the
  required `ui_paths` / `start_cmd`, so a repo block may set just the keys it overrides.
  """
  @spec validate_partial(term(), String.t()) :: [String.t()]
  def validate_partial(%{} = block, label) do
    # A repo block may leave `port_range` to the workspace block: only a range set beside the
    # services can be checked before the merge.
    range_errors =
      if Map.has_key?(block, "port_range"), do: service_range_errors(block, label), else: []

    unknown_errors(block, label) ++ key_errors(block, label) ++ range_errors
  end

  def validate_partial(_block, label), do: ["#{label} must be a map"]

  defp unknown_errors(block, label) do
    case Map.keys(block) -- @keys do
      [] ->
        []

      keys ->
        [
          "#{label} has unknown key(s) #{Enum.join(Enum.sort(Enum.map(keys, &to_string/1)), ", ")} " <>
            "(expected #{Enum.join(@keys, ", ")})"
        ]
    end
  end

  defp required_errors(block, label) do
    for key <- ~w(ui_paths start_cmd), not Map.has_key?(block, key) do
      "#{label}.#{key} is required"
    end
  end

  defp key_errors(block, label) do
    Enum.flat_map(@keys, fn key ->
      case Map.fetch(block, key) do
        :error -> []
        {:ok, value} -> validate_key(key, value, "#{label}.#{key}", block)
      end
    end)
  end

  defp validate_key(key, v, label, _b) when key in ~w(enabled plan_required attach),
    do: if(is_boolean(v), do: [], else: ["#{label} must be a boolean"])

  defp validate_key("ui_paths", v, label, _b), do: glob_list(v, label, :non_empty)
  defp validate_key("ignore_paths", v, label, _b), do: glob_list(v, label, :any)

  defp validate_key("default_routes", v, label, _b) do
    if is_list(v) and Enum.all?(v, &(is_binary(&1) and String.starts_with?(&1, "/"))),
      do: [],
      else: ["#{label} must be a list of paths starting with /"]
  end

  defp validate_key(key, v, label, _b) when key in ~w(start_cmd setup_cmd seed_cmd),
    do: command(v, label)

  defp validate_key("seeds", %{} = v, label, _b),
    do: Enum.flat_map(v, fn {k, c} -> command(c, "#{label}.#{k}") end)

  defp validate_key("seeds", _v, label, _b), do: ["#{label} must be a map of commands"]

  defp validate_key("port_env", v, label, _b) do
    if is_binary(v) and Regex.match?(@env_name, v),
      do: [],
      else: ["#{label} must be an environment variable name"]
  end

  defp validate_key("port_range", v, label, _b) do
    case parse_range(v) do
      {:ok, {lo, hi}} -> range_errors(lo, hi, label)
      :error -> [~s(#{label} must be "lo-hi" or [lo, hi] with lo <= hi)]
    end
  end

  defp validate_key("base_url", v, label, _b), do: base_url(v, label)
  defp validate_key("env", v, label, b), do: env(v, label) ++ deps_managed_env(v, label, b)
  defp validate_key("ready", v, label, _b), do: ready(v, label)
  defp validate_key("login", v, label, _b), do: login(v, label)
  defp validate_key("viewports", v, label, _b), do: viewports(v, label)
  defp validate_key("themes", v, label, _b), do: themes(v, label)

  defp validate_key("default_viewports", v, label, b),
    do: defaults(v, label, Map.keys(Map.merge(@default_viewports, map_or_empty(b["viewports"]))))

  defp validate_key("default_themes", v, label, b),
    do: defaults(v, label, Map.keys(Map.merge(@default_themes, map_or_empty(b["themes"]))))

  defp validate_key("fixture_check", v, label, _b), do: fixture_check(v, label)

  defp validate_key("deny_patterns", v, label, _b), do: deny_patterns(v, label)

  defp validate_key("fixture_email_domains", v, label, _b) do
    if is_list(v) and Enum.all?(v, &(is_binary(&1) and &1 != "")),
      do: [],
      else: ["#{label} must be a list of domains"]
  end

  defp validate_key("limits", v, label, _b), do: limits(v, label)
  defp validate_key("hosting", v, label, _b), do: hosting(v, label)
  defp validate_key("sandbox", v, label, _b), do: sandbox(v, label)
  defp validate_key("services", v, label, _b), do: services(v, label)
  defp validate_key("deps", v, label, b), do: deps(v, label) ++ mix_env_conflict(v, label, b)

  defp map_or_empty(%{} = m), do: m
  defp map_or_empty(_), do: %{}

  defp glob_list(v, label, mode) do
    cond do
      not is_list(v) -> ["#{label} must be a list of globs"]
      mode == :non_empty and v == [] -> ["#{label} must not be empty"]
      true -> Enum.flat_map(v, &glob(&1, label))
    end
  end

  defp glob(g, label) when is_binary(g) and g != "" do
    cond do
      Path.type(g) != :relative -> ["#{label} glob #{inspect(g)} must be repo-relative"]
      ".." in Path.split(g) -> ["#{label} glob #{inspect(g)} must stay in the repo"]
      true -> []
    end
  end

  defp glob(g, label), do: ["#{label} glob #{inspect(g)} must be a non-empty string"]

  defp command(v, label, extra \\ []) do
    if is_binary(v) and String.trim(v) != "",
      do: placeholder_errors(v, label, extra),
      else: ["#{label} must be a non-empty string"]
  end

  defp placeholder_errors(value, label, extra \\ []) do
    known = @placeholders ++ extra

    ~r/\{\{\s*([^{}\s]*)\s*\}\}/
    |> Regex.scan(value)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.reject(&(&1 in known))
    |> Enum.uniq()
    |> Enum.map(&"#{label} uses unknown placeholder {{#{&1}}} (known: #{Enum.join(known, ", ")})")
  end

  defp parse_range(v), do: PreviewConfig.parse_port_range(v)

  defp range_errors(lo, hi, label) do
    {wlo, whi} = @worker_range

    cond do
      lo < 1024 or hi > 65_535 -> ["#{label} must lie within 1024-65535"]
      lo <= whi and hi >= wlo -> ["#{label} overlaps the worker dev-server range #{wlo}-#{whi}"]
      true -> []
    end
  end

  defp base_url(v, label) when is_binary(v) do
    rendered = String.replace(v, ~r/\{\{\s*port\s*\}\}/, "1")

    case URI.parse(rendered) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) ->
        if h in @loopback,
          do: placeholder_errors(v, label),
          else: ["#{label} host must be 127.0.0.1 or localhost"]

      _ ->
        ["#{label} must be an http(s) URL"]
    end
  end

  defp base_url(_v, label), do: ["#{label} must be a string"]

  defp env(%{} = env, label) do
    Enum.flat_map(env, fn
      {k, v} when is_binary(k) and is_binary(v) -> env_pair(k, v, label)
      {k, _} when is_binary(k) -> ["#{label}.#{k} must be a string"]
      {k, _} -> ["#{label} key #{inspect(k)} is not a valid environment variable name"]
    end)
  end

  defp env(_v, label), do: ["#{label} must be a map of strings"]

  defp env_pair(k, v, label) do
    cond do
      not Regex.match?(@env_name, k) ->
        ["#{label} key #{inspect(k)} is not a valid environment variable name"]

      String.upcase(k) in @proxy_keys ->
        ["#{label}.#{k} may not be set (the capture pass sets its own proxy rules)"]

      scrubbed?(k) ->
        ["#{label}.#{k} may not be set (scrubbed from worker environments)"]

      true ->
        foreign_host_errors(v, "#{label}.#{k}") ++ placeholder_errors(v, "#{label}.#{k}")
    end
  end

  defp scrubbed?(k), do: k in SpawnEnv.credential_names() or String.starts_with?(k, "CODEX_")

  # A URL or `host:port` whose host is not loopback.
  defp foreign_host_errors(value, label) do
    value = String.replace(value, ~r/\{\{[^{}]*\}\}/, "1")

    hosts =
      Regex.scan(~r{[a-z][a-z0-9+.-]*://(?:[^/@\s]*@)?([^/:\s?#]+)}i, value,
        capture: :all_but_first
      ) ++
        Regex.scan(
          ~r"(?<![/\w.@-])((?:[a-z0-9-]+\.)+[a-z0-9-]*[a-z][a-z0-9-]*|\d+\.\d+\.\d+\.\d+):\d{2,5}\b"i,
          value,
          capture: :all_but_first
        )

    if Enum.all?(List.flatten(hosts), &(String.downcase(&1) in @loopback)),
      do: [],
      else: ["#{label} may not point at a non-loopback host"]
  end

  defp ready(%{} = v, label) do
    unknown_keys(v, ~w(path timeout_seconds expect), label) ++
      check(
        v,
        "path",
        label,
        &(is_binary(&1) and String.starts_with?(&1, "/")),
        "must start with /"
      ) ++
      check(v, "timeout_seconds", label, &(is_integer(&1) and &1 in 1..3600), "must be 1-3600") ++
      check(v, "expect", label, &(&1 in ~w(below_500 2xx)), ~s(must be "below_500" or "2xx"))
  end

  defp ready(_v, label), do: ["#{label} must be a map"]

  defp unknown_keys(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] -> []
      keys -> ["#{label} has unknown key(s) #{Enum.join(Enum.sort(keys), ", ")}"]
    end
  end

  # An error unless `key` is absent or its value satisfies `pred`.
  defp check(map, key, label, pred, message) do
    case Map.fetch(map, key) do
      {:ok, value} -> if pred.(value), do: [], else: ["#{label}.#{key} #{message}"]
      :error -> []
    end
  end

  defp login(%{"kind" => "none"}, _label), do: []

  defp login(%{"kind" => "form"} = v, label) do
    strings =
      for k <- ~w(path username_selector password_selector submit_selector),
          not (is_binary(v[k]) and v[k] != ""),
          do: "#{label}.#{k} must be a non-empty string"

    strings ++
      success(v["success"], label) ++
      post_login_path(v, label) ++
      ready_selector(v, label) ++
      personas_form(v["personas"], label) ++
      default_persona(v, label, persona_names(v["personas"]))
  end

  # `ready_selector`: a CSS selector the CDP shooter waits for on the sign-in page before it
  # fills the form. Unset, a LiveView page (`[data-phx-main]`) is awaited until it is connected.
  defp ready_selector(%{"ready_selector" => s}, label) do
    if is_binary(s) and s != "",
      do: [],
      else: ["#{label}.ready_selector must be a non-empty string"]
  end

  defp ready_selector(_v, _label), do: []

  defp login(%{"kind" => "cmd"} = v, label) do
    cmd = command(v["cmd"], "#{label}.cmd", ["persona"]) ++ success(v["success"], label)

    names =
      case v["personas"] do
        l when is_list(l) and l != [] and is_list(l) -> l
        _ -> nil
      end

    personas =
      if is_list(names) and Enum.all?(names, &(is_binary(&1) and &1 != "")),
        do: [],
        else: ["#{label}.personas must be a non-empty list of names"]

    cmd ++ personas ++ default_persona(v, label, if(is_list(names), do: names, else: []))
  end

  defp login(%{} = _v, label), do: [~s(#{label}.kind must be "none", "form" or "cmd")]
  defp login(_v, label), do: ["#{label} must be a map"]

  @success_keys ~w(path_not url_not_contains)

  # `login.success` is how the CDP shooter proves a login worked before it shoots anything: after
  # submitting, the page's URL must satisfy every condition given. `path_not` is a path the
  # browser must have left (`"/login"`); `url_not_contains` a substring its URL must not carry
  # (`"/sign-in"`). Each condition must be FALSE on the sign-in page itself, or it cannot tell a
  # failed login from a good one: the runner refuses it at shot time (so `"error="`, which the
  # sign-in page's own URL lacks, is no condition at all; pair it with `path_not`). Nothing else is
  # accepted: a shape this does not know would be silently ignored, and an ignored success check
  # is a picture of the sign-in page.
  defp success(nil, _label), do: []

  defp success(%{} = s, label) when map_size(s) > 0 do
    unknown =
      case Map.keys(s) -- @success_keys do
        [] ->
          []

        keys ->
          [
            "#{label}.success has unknown key(s) #{Enum.join(Enum.sort(keys), ", ")}; use path_not or url_not_contains"
          ]
      end

    unknown ++
      check(s, "path_not", "#{label}.success", &path_not?/1, "must be a path starting with /") ++
      check(
        s,
        "url_not_contains",
        "#{label}.success",
        &(is_binary(&1) and &1 != "" and String.length(&1) <= 200),
        "must be a non-empty string of at most 200 characters"
      )
  end

  defp success(_s, label),
    do: ["#{label}.success must be a map with path_not and/or url_not_contains"]

  defp path_not?(p), do: is_binary(p) and String.starts_with?(p, "/") and String.length(p) <= 300

  @doc """
  The success condition of a `login` map: its `success`, or, when unset, "the browser has left the
  login `path`" (`%{"path_not" => path}`), so a login that lands back on the sign-in page always
  fails.
  """
  @spec login_success(map()) :: map()
  def login_success(%{"success" => %{} = success}) when map_size(success) > 0, do: success

  def login_success(%{"path" => path}),
    do: %{"path_not" => path |> String.split(["?", "#"]) |> hd()}

  defp personas_form(%{} = p, label) when map_size(p) > 0 do
    Enum.flat_map(p, fn
      {n, %{"username" => u, "password" => pw} = persona} when is_binary(u) and is_binary(pw) ->
        persona
        |> Map.drop(["username", "password"])
        |> Enum.reject(fn {k, v} ->
          is_binary(k) and k =~ ~r/^[a-z][a-z0-9_]*$/ and is_binary(v)
        end)
        |> Enum.map(fn {k, _} ->
          "#{label}.personas.#{n}.#{k} must be a string under a lowercase [a-z0-9_] key"
        end)

      {n, _} ->
        ["#{label}.personas.#{n} needs a username and password (fixture credentials only)"]
    end)
  end

  defp personas_form(_p, label), do: ["#{label}.personas must be a non-empty map"]

  # `post_login_path` (bd-b2e1ev): a path the browser opens once after a successful login and
  # before the shot, e.g. a tenant switch for a persona that belongs to several tenants:
  # `"/switch-tenant/{{persona.tenant_id}}?return_to={{return_to}}"`. `{{persona.<key>}}` is a
  # string field of the shot's persona (beyond username/password), `{{return_to}}` the shot's
  # own path, both URL-encoded. It stays on the app: it must start with a single `/`.
  @post_login_var ~r/\{\{\s*([^}]*?)\s*\}\}/

  defp post_login_path(%{"post_login_path" => path} = v, label) do
    if is_binary(path) and String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      post_login_vars(path, persona_fields(v["personas"]), label)
    else
      ["#{label}.post_login_path must be a path on the app, starting with a single /"]
    end
  end

  defp post_login_path(_v, _label), do: []

  defp persona_fields(%{} = personas) do
    personas
    |> Map.values()
    |> Enum.flat_map(&if(is_map(&1), do: Map.keys(&1) -- ["username", "password"], else: []))
  end

  defp persona_fields(_), do: []

  defp post_login_vars(path, fields, label) do
    for [_, name] <- Regex.scan(@post_login_var, path),
        not post_login_var_ok?(name, fields),
        do:
          "#{label}.post_login_path uses {{#{name}}}, which is neither return_to nor a persona field"
  end

  defp post_login_var_ok?("return_to", _fields), do: true
  defp post_login_var_ok?("persona." <> field, fields), do: field in fields
  defp post_login_var_ok?(_name, _fields), do: false

  defp persona_names(%{} = p), do: Map.keys(p)
  defp persona_names(_), do: []

  defp default_persona(v, label, names) do
    case v["default_persona"] do
      nil -> []
      d -> if d in names, do: [], else: ["#{label}.default_persona must name one of the personas"]
    end
  end

  defp viewports(%{} = v, label) do
    Enum.flat_map(v, fn {name, spec} ->
      l = "#{label}.#{name}"

      cond do
        not (is_binary(name) and Regex.match?(@name, name)) ->
          ["#{label} name #{inspect(name)} must match [a-z0-9-]{1,20}"]

        not is_map(spec) ->
          ["#{l} must be a map"]

        true ->
          dim(spec["width"], l <> ".width", 200..3840) ++
            dim(spec["height"], l <> ".height", 200..4000) ++
            scale(spec["device_scale_factor"], l)
      end
    end)
  end

  defp viewports(_v, label), do: ["#{label} must be a map"]

  defp dim(n, label, range) do
    if is_integer(n) and n in range,
      do: [],
      else: ["#{label} must be #{range.first}-#{range.last}"]
  end

  defp scale(nil, _l), do: []

  defp scale(s, l) do
    if is_number(s) and s >= 1 and s <= 3, do: [], else: ["#{l}.device_scale_factor must be 1-3"]
  end

  defp themes(%{} = v, label) do
    Enum.flat_map(v, fn {name, spec} ->
      cond do
        not (is_binary(name) and Regex.match?(@name, name)) ->
          ["#{label} name #{inspect(name)} must match [a-z0-9-]{1,20}"]

        not is_map(spec) ->
          ["#{label}.#{name} must be a map"]

        spec["color_scheme"] not in [nil, "light", "dark"] ->
          [~s(#{label}.#{name}.color_scheme must be "light" or "dark")]

        true ->
          []
      end
    end)
  end

  defp themes(_v, label), do: ["#{label} must be a map"]

  defp defaults(v, label, known) do
    if is_list(v) and v != [] and Enum.all?(v, &(&1 in known)),
      do: [],
      else: [
        "#{label} must be a non-empty list of configured names (#{Enum.join(Enum.sort(known), ", ")})"
      ]
  end

  defp fixture_check(%{"marker" => %{"path" => p, "contains" => c} = marker}, _label)
       when is_binary(p) and is_binary(c) and c != "" do
    Enum.reject(
      [
        if(String.starts_with?(p, "/"),
          do: nil,
          else: "fixture_check.marker.path must start with /"
        ),
        if(is_boolean(Map.get(marker, "auth", true)),
          do: nil,
          else: "fixture_check.marker.auth must be true or false"
        )
      ],
      &is_nil/1
    )
  end

  defp fixture_check(_v, label),
    do: [
      ~s(#{label} must be {"marker": {"path": "/..", "contains": ".."}} ) <>
        ~s[(optionally "auth": false to probe without logging in)]
    ]

  defp deny_patterns(v, label) when is_list(v) do
    Enum.flat_map(v, fn
      p when is_binary(p) ->
        case Regex.compile(p) do
          {:ok, _} -> []
          {:error, _} -> ["#{label} pattern #{inspect(p)} is not a valid regex"]
        end

      p ->
        ["#{label} pattern #{inspect(p)} must be a string"]
    end)
  end

  defp deny_patterns(_v, label), do: ["#{label} must be a list of regexes"]

  defp limits(%{} = v, label) do
    unknown = Map.keys(v) -- (Map.keys(@default_limits) ++ @retired_limits)

    unknown_errors =
      if unknown == [],
        do: [],
        else: ["#{label} has unknown key(s) #{Enum.join(Enum.sort(unknown), ", ")}"]

    unknown_errors ++
      Enum.flat_map(Map.drop(v, unknown), fn
        {"memory", m} -> memory(m, label)
        {k, n} -> positive_limit(k, n, label)
      end)
  end

  defp limits(_v, label), do: ["#{label} must be a map"]

  defp positive_limit(k, n, label) do
    max = Map.get(@limit_max, k)

    cond do
      not (is_integer(n) and n > 0) -> ["#{label}.#{k} must be a positive integer"]
      max && n > max -> ["#{label}.#{k} must be at most #{max}"]
      true -> []
    end
  end

  defp memory(m, label) do
    case is_binary(m) && Regex.run(~r/\A(\d+)([mg])\z/, m) do
      [_, n, unit] ->
        gib = String.to_integer(n) / if(unit == "g", do: 1, else: 1024)

        if gib > 0 and gib <= @max_memory_gib,
          do: [],
          else: ["#{label}.memory must be > 0 and at most #{@max_memory_gib}g"]

      _ ->
        [~s(#{label}.memory must look like "512m" or "4g")]
    end
  end

  defp hosting(%{} = v, label) do
    unknown_keys(v, ~w(github public_repo_ok retention_days), label) ++
      check(v, "public_repo_ok", label, &is_boolean/1, "must be a boolean") ++
      check(
        v,
        "retention_days",
        label,
        &(is_integer(&1) and &1 > 0),
        "must be a positive integer"
      ) ++
      check(
        v,
        "github",
        label,
        &github_hosting?/1,
        ~s(must be {"mode": "assets_branch", "branch": ".."})
      )
  end

  defp hosting(_v, label), do: ["#{label} must be a map"]

  defp github_hosting?(%{"mode" => "assets_branch", "branch" => b}), do: is_binary(b) and b != ""
  defp github_hosting?(_), do: false

  # bd-bhrsdv: what the capture sandbox shows of the host beyond its system directories.
  defp sandbox(%{} = v, label) do
    paths_label = "#{label}.readonly_paths"

    unknown_keys(v, ~w(readonly_paths), label) ++
      case Map.get(v, "readonly_paths", []) do
        paths when is_list(paths) -> Enum.flat_map(paths, &readonly_path(&1, paths_label))
        _ -> ["#{paths_label} must be a list of paths"]
      end
  end

  defp sandbox(_v, label), do: ["#{label} must be a map"]

  # A path the sandbox shows read-only (a toolchain, a dependency cache): absolute or under `~/`,
  # and never the home directory or anything above it, which would hand the app the very files
  # the sandbox exists to hide.
  defp readonly_path(path, label) when is_binary(path) and path != "" do
    cond do
      not (String.starts_with?(path, "/") or String.starts_with?(path, "~/")) ->
        ["#{label}: #{inspect(path)} must be an absolute path or start with ~/"]

      covers_home?(Path.expand(path)) ->
        [
          "#{label}: #{inspect(path)} would show the whole home directory (or more) to the " <>
            "app; list only the directories it needs"
        ]

      true ->
        []
    end
  end

  defp readonly_path(path, label), do: ["#{label}: #{inspect(path)} must be a non-empty path"]

  defp covers_home?("/"), do: true

  defp covers_home?(expanded) do
    home = Path.expand(System.user_home() || "/")
    String.starts_with?(home <> "/", expanded <> "/")
  end

  # ── services and deps (bd-3glf2a) ───────────────────────────────────────

  defp services(%{} = v, label) do
    Enum.flat_map(Enum.sort(v), fn {name, svc} -> service(name, svc, "#{label}.#{name}") end) ++
      shared_values(v, "port", label) ++
      shared_values(v, "socket", label) ++ nested_sockets(v, label)
  end

  defp services(_v, label), do: ["#{label} must be a map of service name -> service"]

  # bwrap cannot bind a socket at a path inside another bound socket.
  defp nested_sockets(services, label) do
    sockets =
      for {name, %{"socket" => s}} <- Enum.sort(services), is_binary(s), do: {name, s}

    for {outer_name, outer} <- sockets,
        {inner_name, inner} <- sockets,
        String.starts_with?(inner, outer <> "/") do
      "#{label}: service #{inner_name}'s socket #{inner} is inside service #{outer_name}'s " <>
        "socket #{outer}"
    end
  end

  defp service(name, svc, label) do
    cond do
      not (is_binary(name) and Regex.match?(@service_name, name)) ->
        ["#{label}: a service name is 1-16 characters of a-z, 0-9 and -, starting with a letter"]

      not is_map(svc) ->
        ["#{label} must be a map"]

      true ->
        unknown_keys(svc, @service_keys, label) ++
          for(
            key <- ~w(image port),
            not Map.has_key?(svc, key),
            do: "#{label}.#{key} is required"
          ) ++
          service_fields(svc, label)
    end
  end

  defp service_fields(svc, label) do
    check(
      svc,
      "image",
      label,
      &(is_binary(&1) and Regex.match?(@image_ref, &1)),
      "must be an image reference (no spaces, not starting with -)"
    ) ++
      check(
        svc,
        "port",
        label,
        &(is_integer(&1) and &1 in 1024..65_535),
        "must be an integer in 1024-65535 (the sandbox cannot bind a lower one)"
      ) ++
      service_env(Map.get(svc, "env", %{}), "#{label}.env") ++
      check(svc, "command", label, &strings?/1, "must be a list of strings") ++
      service_ready(svc, label) ++ service_socket(svc, label)
  end

  # Literal values: the container gets them as written (no template is rendered there).
  defp service_env(%{} = env, label) do
    Enum.flat_map(env, fn
      {k, v} when is_binary(k) and is_binary(v) -> service_env_pair(k, v, label)
      {k, _} when is_binary(k) -> ["#{label}.#{k} must be a string"]
      {k, _} -> ["#{label} key #{inspect(k)} is not a valid environment variable name"]
    end)
  end

  defp service_env(_v, label), do: ["#{label} must be a map of strings"]

  defp service_env_pair(k, v, label) do
    cond do
      not Regex.match?(@env_name, k) ->
        ["#{label} key #{inspect(k)} is not a valid environment variable name"]

      String.upcase(k) in @proxy_keys ->
        ["#{label}.#{k} may not be set (the service has no network to proxy)"]

      scrubbed?(k) ->
        ["#{label}.#{k} may not be set (scrubbed from worker environments)"]

      String.contains?(v, ["{{", "\0"]) ->
        ["#{label}.#{k} must be a literal value (no {{placeholder}} is rendered here)"]

      true ->
        []
    end
  end

  defp strings?(list),
    do: is_list(list) and Enum.all?(list, &(is_binary(&1) and not String.contains?(&1, "\0")))

  defp service_ready(%{"ready" => %{} = ready}, label) do
    label = "#{label}.ready"

    unknown_keys(ready, ~w(cmd tcp timeout_seconds), label) ++
      ready_kind(Map.fetch(ready, "cmd"), Map.fetch(ready, "tcp"), label) ++
      check(
        ready,
        "timeout_seconds",
        label,
        &(is_integer(&1) and &1 in 1..@service_ready_max_s),
        "must be 1-#{@service_ready_max_s}"
      )
  end

  defp service_ready(%{"ready" => _}, label), do: ["#{label}.ready must be a map"]
  defp service_ready(_svc, _label), do: []

  defp ready_kind({:ok, _}, {:ok, _}, label), do: ["#{label} takes cmd or tcp, not both"]

  defp ready_kind(:error, :error, label) do
    [
      "#{label} needs cmd (an argv run in the service until it exits 0) or tcp: true " <>
        "(the port accepts a connection)"
    ]
  end

  defp ready_kind({:ok, cmd}, :error, label) do
    if strings?(cmd) and cmd != [],
      do: [],
      else: ["#{label}.cmd must be a non-empty list of strings"]
  end

  defp ready_kind(:error, {:ok, tcp}, label),
    do: if(tcp == true, do: [], else: ["#{label}.tcp must be true"])

  # Where the service also shows as a Unix socket inside the sandbox: on its private /run or /tmp
  # (bwrap makes the mount point there), short enough for sun_path.
  defp service_socket(%{"socket" => socket}, label) do
    label = "#{label}.socket"

    cond do
      not is_binary(socket) ->
        ["#{label} must be a path"]

      byte_size(socket) > @max_socket_bytes ->
        ["#{label} is longer than #{@max_socket_bytes} bytes, too long for a Unix socket"]

      not Regex.match?(@service_socket, socket) ->
        ["#{label} must be an absolute path under /run/ or /tmp/ (letters, digits, . _ - /)"]

      Enum.any?(Path.split(socket), &(&1 in [".", ".."])) or String.ends_with?(socket, "/") ->
        ["#{label} must name a file, with no . or .. segment"]

      true ->
        []
    end
  end

  defp service_socket(_svc, _label), do: []

  # Two services on one sandbox port (or socket path) would collide inside the sandbox.
  defp shared_values(services, key, label) do
    services
    |> Enum.filter(fn {_name, svc} -> is_map(svc) and scalar?(svc[key]) end)
    |> Enum.group_by(fn {_name, svc} -> svc[key] end, &elem(&1, 0))
    |> Enum.filter(fn {_value, names} -> length(names) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {value, names} ->
      "#{label}: services #{Enum.join(Enum.sort(names), ", ")} share #{key} #{value}"
    end)
  end

  defp scalar?(v), do: is_integer(v) or is_binary(v)

  # The app's own port is picked from `port_range`, inside the same sandbox namespace.
  defp service_range_errors(%{"services" => %{} = services} = block, label) do
    case parse_range(Map.get(block, "port_range", "32000-32999")) do
      {:ok, {lo, hi}} ->
        for {name, %{"port" => port}} <- Enum.sort(services),
            is_integer(port) and port in lo..hi do
          "#{label}.services.#{name}.port #{port} is inside port_range #{lo}-#{hi}, where the " <>
            "app's own port is picked"
        end

      _ ->
        []
    end
  end

  defp service_range_errors(_block, _label), do: []

  defp deps(%{} = v, label),
    do:
      unknown_keys(v, ~w(mix mix_env env), label) ++
        check(v, "mix", label, &is_boolean/1, "must be a boolean") ++
        check(
          v,
          "mix_env",
          label,
          &(is_binary(&1) and Regex.match?(@mix_env, &1)),
          "must be a Mix environment name (lowercase letters, digits and _)"
        ) ++ deps_env(Map.get(v, "env", %{}), "#{label}.env")

  defp deps(_v, label), do: ["#{label} must be a map"]

  # A cache compiled under one env is no use to a boot of another.
  defp mix_env_conflict(%{"mix_env" => seed}, label, %{"env" => %{"MIX_ENV" => boot}})
       when is_binary(seed) and is_binary(boot) and seed != boot,
       do: ["#{label}.mix_env #{inspect(seed)} differs from env.MIX_ENV #{inspect(boot)}"]

  defp mix_env_conflict(_deps, _label, _block), do: []

  # bd-ur1zty: the seed runs trusted code with the network on, so what it is given is the
  # config's literal values and nothing else: no placeholder (there is no boot to render it for),
  # no credential the server scrubs from worker environments (`env/2`), nothing the seed or the
  # cache sets itself.
  defp deps_env(%{} = env, label) do
    env(env, label) ++
      for {k, v} <- Enum.sort(env),
          is_binary(k),
          is_binary(v),
          error <- deps_env_pair(k, v, label),
          do: error
  end

  defp deps_env(_v, label), do: ["#{label} must be a map of strings"]

  defp deps_env_pair(k, v, label) do
    reserved =
      cond do
        k == "MIX_ENV" -> ["#{label}.#{k} is set by deps.mix_env"]
        k in @seed_reserved or k in @deps_env -> ["#{label}.#{k} is set by the seed itself"]
        true -> []
      end

    templated =
      if String.contains?(v, "{{"),
        do: ["#{label}.#{k} may not use a placeholder (the seed is not a boot)"],
        else: []

    reserved ++ templated
  end

  @doc """
  What the offline deps seed (`Capture.DepsCache`) runs with (bd-ur1zty): `%{mix_env:, env:}`.

  `mix_env` is `deps.mix_env`, else the `MIX_ENV` the boot's `env` sets, else `"dev"`: the cache
  is compiled under the env the boot uses. `env` is the boot's literal `env` values (a strict
  `config/runtime.exs` wants the same `DATABASE_URL` the boot gets; a templated value is the
  boot's own and is left out) with `deps.env` over them, as `[{name, value}]`. Both are values
  written in the screenshots config: the seed never gets the server's own environment.
  """
  @spec deps_seed(t()) :: %{mix_env: String.t(), env: [{String.t(), String.t()}]}
  def deps_seed(%__MODULE__{env: env, deps: deps}) do
    boot =
      for {k, v} <- env, k != "MIX_ENV", not String.contains?(v, "{{"), into: %{}, do: {k, v}

    %{
      mix_env: Map.get(deps, "mix_env") || Map.get(env, "MIX_ENV") || "dev",
      env: boot |> Map.merge(Map.get(deps, "env", %{})) |> Enum.sort()
    }
  end

  # With the deps cache on, these point at it; a hand-set value would quietly undo that.
  defp deps_managed_env(%{} = env, label, %{"deps" => %{"mix" => true}}) do
    for key <- Enum.sort(Map.keys(env)), key in @deps_env do
      "#{label}.#{key} is set by the offline deps cache (deps.mix); remove it from env"
    end
  end

  defp deps_managed_env(_env, _label, _block), do: []
end
