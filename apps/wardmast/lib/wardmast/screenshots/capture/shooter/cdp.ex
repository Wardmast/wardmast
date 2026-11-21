defmodule Wardmast.Screenshots.Capture.Shooter.Cdp do
  @moduledoc """
  The CDP `Wardmast.Screenshots.Capture.Shooter` of the design's N1: headless Chromium driven over
  the DevTools protocol by `playwright-core`, through the `arb-capture` runner
  (`priv/capture/runner.mjs`). It does what the command-line `Shooter.Chromium` cannot: a **form
  login**, `steps`, `wait_for`, a `target` element, `full_page`, `hide` and a theme's
  `local_storage`. `Shooter.Auto` picks between the two.

  One runner process per image, one fresh browser context per image (so no shot sees another's
  session). The runner is a plain executor of a declarative spec this module writes
  (`build_spec/2`): no worker-supplied code, no command, only paths, selectors and the operator's
  config.

  ## Login

  `login.kind` `"form"`: the runner opens `login.path`, fills `username_selector` and
  `password_selector` with the persona's fixture credentials (`entry.as`, else
  `login.default_persona`, else the only persona), clicks `submit_selector` and then checks the
  URL against `login.success` (`Wardmast.Screenshots.Config.login_success/1`: `path_not` and/or
  `url_not_contains`, default "left `login.path`"). If it does not hold, the shot **fails** with
  the reason; the sign-in page is never shot as a result. The shot's own route landing back on the
  sign-in page fails the same way. `login.kind` `"cmd"` is not supported here.

  ## Isolation and determinism

  Node and Chromium never run on the host as themselves. The runner is started through the capture
  sandbox's `browser/4` (`Wardmast.Screenshots.Capture.Sandbox`), as `Shooter.Chromium` starts its
  browser: a namespace of its own with no network but the bridge from `127.0.0.1:<port>` to the
  booted app, the capture directory and Chromium read-only, the shot's `scratch` directory the only
  writable path, and an environment built from nothing (`env -i`). That is also what makes
  Chromium's `--no-sandbox` acceptable (see `Shooter.Chromium`), and why `base_url` is reachable at
  all: the app listens inside its own sandbox, which the host cannot dial. A spec without a sandbox
  or the boot's `app` starts nothing (`{:error, {:shot, "no capture sandbox ..."}}`).

  The runner also refuses a non-loopback `base_url`, resolves no host but loopback inside the browser
  and aborts any request to one; timezone UTC, locale `en-US`, the viewport's size and scale, the
  theme's colour scheme, reduced motion, animations off and a frozen clock
  (`2026-01-01T12:00:00Z`). A 404 from the route is `{:error, {:http_status, 404}}` (absent at this
  commit), as for the other shooter.

  ## Where things come from

  The capture directory (`runner.mjs` and its `node_modules`) is `ctx[:capture_dir]`,
  `$ARB_CAPTURE_DIR` (the worker image sets `/opt/arbiter/capture`), else this app's
  `priv/capture` (run `npm ci` there on a host). Node is `ctx[:node]`, `$ARB_CAPTURE_NODE`, the
  directory's own `bin/node` (the image ships one), else `node` on `PATH`. Chromium is
  `ctx[:chrome]`, `$ARB_CHROME`, else `chromium` on `PATH`. Anything missing is an
  `{:error, {:shot, reason}}` naming it. `available/1` reports that without shooting.
  """

  @behaviour Wardmast.Screenshots.Capture.Shooter

  alias Wardmast.Screenshots.Capture.Shooter.Chromium
  alias Wardmast.Screenshots.Config
  alias Wardmast.Worker.ReleaseEnv

  @fixed_time "2026-01-01T12:00:00Z"

  @impl true
  def shoot(spec) do
    with {:ok, sandbox, app} <- Chromium.sandboxed(spec),
         {:ok, login} <- login(spec),
         {:ok, tools} <- tools(spec),
         {:ok, chrome} <- chrome(spec) do
      run(tools, chrome, login, spec, sandbox, app)
    end
  end

  @doc """
  `:ok` when the runner could run here (`node`, the runner file and `playwright-core`, and a
  Chromium), else `{:error, reason}`. `ctx` is the shot's `ctx` (see the moduledoc).
  """
  @spec available(map() | nil) :: :ok | {:error, String.t()}
  def available(ctx) do
    spec = %{ctx: ctx}

    with {:ok, tools} <- tools(spec),
         :ok <- playwright_core(tools),
         {:ok, _chrome} <- chrome(spec) do
      :ok
    else
      {:error, {:shot, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp playwright_core(%{dir: dir, node_override?: false}) do
    if File.dir?(Path.join([dir, "node_modules", "playwright-core"])),
      do: :ok,
      else: {:error, "playwright-core is not installed in #{dir} (run `npm ci` there)"}
  end

  defp playwright_core(_tools), do: :ok

  # Resolves the shot's login itself; a refusal (unsupported kind, no persona) raises, as
  # `shoot/1` never reaches here with one. For callers that have not resolved the login.
  @doc false
  @spec build_spec(map(), String.t()) :: map()
  def build_spec(spec, chrome) do
    {:ok, login} = login(spec)
    build_spec(spec, chrome, login)
  end

  @doc false
  @spec build_spec(map(), String.t(), map() | nil) :: map()
  def build_spec(spec, chrome, login) do
    entry = spec.entry

    %{
      "chrome" => chrome,
      "base_url" => spec.base_url,
      "path" => spec.path,
      "out_file" => spec.out_file,
      "timeout_ms" => spec.timeout_s * 1000,
      "fixed_time" => @fixed_time,
      "viewport" => spec.viewport,
      "theme" => Map.take(spec.theme, ~w(color_scheme local_storage query)),
      "shot" => %{
        "steps" => entry.steps,
        "wait_for" => entry.wait_for,
        "target" => entry.target,
        "full_page" => entry.full_page,
        "hide" => entry.hide
      },
      "login" => login
    }
  end

  # ── the login block ─────────────────────────────────────────────────────

  defp login(%{config: %{login: %{"kind" => kind}}}) when kind in [nil, "none"], do: {:ok, nil}

  defp login(%{config: %{login: %{"kind" => "form"} = login}, entry: entry} = spec) do
    with {:ok, persona, creds} <- persona(login, entry),
         {:ok, post} <- post_login_path(login, persona, creds, spec) do
      {:ok,
       Map.merge(
         Map.take(login, ~w(kind path username_selector password_selector submit_selector)),
         %{
           "persona" => persona,
           "username" => creds["username"],
           "password" => creds["password"],
           "success" => Config.login_success(login),
           "post_login_path" => post
         }
       )}
    end
  end

  defp login(%{config: %{login: %{"kind" => kind}}}) do
    {:error,
     {:shot,
      "login.kind #{inspect(kind)} is not supported by the CDP shooter (only \"form\" and \"none\")"}}
  end

  # `login.post_login_path` with `{{persona.<key>}}` (a string field of the persona) and
  # `{{return_to}}` (the shot's path) filled in, each URL-encoded. A reference the persona cannot
  # satisfy refuses the shot rather than opening a half-filled path.
  defp post_login_path(%{"post_login_path" => template}, name, creds, spec)
       when is_binary(template) do
    vars = creds |> Map.drop(["username", "password"]) |> Map.put("return_to", spec.path)

    Regex.scan(~r/\{\{\s*([^}]*?)\s*\}\}/, template)
    |> Enum.reduce_while({:ok, template}, fn [whole, ref], {:ok, acc} ->
      key = String.replace_prefix(ref, "persona.", "")

      case Map.get(vars, key) do
        value when is_binary(value) and value != "" ->
          {:cont, {:ok, String.replace(acc, whole, URI.encode_www_form(value))}}

        _ ->
          {:halt,
           {:error,
            {:shot,
             "login.post_login_path needs {{#{ref}}}, which persona #{inspect(name)} does not set"}}}
      end
    end)
  end

  defp post_login_path(_login, _name, _creds, _spec), do: {:ok, nil}

  defp persona(login, entry) do
    personas = login["personas"] || %{}

    name =
      entry.as || login["default_persona"] ||
        case Map.keys(personas) do
          [only] -> only
          _ -> nil
        end

    case Map.fetch(personas, name) do
      {:ok, creds} when is_map(creds) ->
        {:ok, name, creds}

      _ ->
        {:error,
         {:shot,
          "#{entry.id} needs a login persona: set login.default_persona or give the shot an " <>
            "\"as\" (configured: #{personas |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"}}
    end
  end

  # ── tools ───────────────────────────────────────────────────────────────

  defp ctx(spec), do: if(is_map(spec.ctx), do: spec.ctx, else: %{})

  defp tools(spec) do
    ctx = ctx(spec)

    dir = capture_dir(ctx)
    runner = Path.join(dir, "runner.mjs")
    override = ctx[:node] || System.get_env("ARB_CAPTURE_NODE")
    node = override || bundled_node(dir) || System.find_executable("node")

    cond do
      not File.exists?(runner) ->
        {:error, {:shot, "the capture runner #{runner} is missing"}}

      is_nil(node) or not File.exists?(node) ->
        {:error,
         {:shot,
          "no node found to run the capture runner (set ARB_CAPTURE_NODE, or use a worker image, " <>
            "which ships one)"}}

      true ->
        {:ok, %{dir: dir, runner: runner, node: node, node_override?: override != nil}}
    end
  end

  defp capture_dir(ctx) do
    ctx[:capture_dir] || System.get_env("ARB_CAPTURE_DIR") ||
      Application.app_dir(:wardmast, "priv/capture")
  end

  defp bundled_node(dir) do
    bundled = Path.join([dir, "bin", "node"])
    if File.exists?(bundled), do: bundled
  end

  defp chrome(spec) do
    case Chromium.chrome(spec) do
      {:ok, chrome} -> {:ok, chrome}
      {:error, _} -> {:error, {:shot, "no headless Chromium found (set ARB_CHROME)"}}
    end
  end

  # ── run ─────────────────────────────────────────────────────────────────

  # Node and Chromium run in the capture's browser sandbox (`sandbox.browser/4`), exactly as
  # `Shooter.Chromium` runs its browser: the argv is wrapped, run under `env -i` with an
  # environment built from nothing, and the shot is written into the shot's own `scratch` dir (the
  # only writable path) and copied to `out_file` only when it is a regular file. `node` is the
  # operator-configured or image-shipped binary and the argv is a list handed to `ReleaseEnv.cmd/3`
  # directly, never through a shell; the spec file carries the worker-declared values as data the
  # runner reads (and deletes at once), not as arguments.
  defp run(tools, chrome, login, spec, sandbox, app) do
    dir = spec.scratch
    shot = Path.join(dir, "shot.png")
    home = Path.join(dir, "home")
    spec_file = Path.join(dir, "cdp-spec.json")
    File.mkdir_p!(home)

    try do
      write_spec(spec_file, build_spec(%{spec | out_file: shot}, chrome, login))
      argv = [tools.node, tools.runner, spec_file]

      with {:ok, boxed} <- boxed(sandbox, argv, app, dir, [tools.dir, chrome]) do
        env = [System.find_executable("env") || "/usr/bin/env", "-i" | Chromium.browser_env(home)]
        {exec, args} = Chromium.with_timeout(env ++ boxed, spec.timeout_s * 2 + 10)

        {out, code} = ReleaseEnv.cmd(exec, args, stderr_to_stdout: true)
        interpret(out, code, shot, spec.out_file)
      end
    after
      File.rm_rf(dir)
    end
  end

  # It can hold a fixture password: owner-only from the first byte (created empty and chmodded
  # before anything is written, so there is no window under the process umask).
  defp write_spec(path, json) do
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, Jason.encode!(json))
  end

  defp boxed(sandbox, argv, app, dir, readonly) do
    case sandbox.browser(argv, app, [dir], readonly) do
      {:ok, boxed} ->
        {:ok, boxed}

      {:error, reason} ->
        {:error,
         {:shot,
          "the capture sandbox could not start the browser: #{Chromium.describe(sandbox, reason)}"}}
    end
  end

  # The runner's answer is the last line of output that is a JSON object with an `ok` key. No such
  # line is never a success, whatever the exit status.
  defp interpret(out, code, shot, out_file) do
    case answer(out) do
      %{"ok" => true} ->
        collect(shot, out_file)

      %{"ok" => false, "kind" => "http_status", "status" => status} when is_integer(status) ->
        {:error, {:http_status, status}}

      %{"ok" => false} = answer ->
        {:error, {:shot, to_string(answer["reason"] || "the capture runner failed")}}

      nil when code == 0 ->
        {:error, {:shot, "the capture runner gave no answer: #{Chromium.tail(out)}"}}

      nil ->
        {:error, {:shot, "the capture runner exited with status #{code}: #{Chromium.tail(out)}"}}
    end
  end

  defp answer(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"ok" => ok} = answer} when is_boolean(ok) -> answer
        _ -> nil
      end
    end)
  end

  # The image the runner left in the shot's own directory, copied out only when it is a plain
  # file: a symlink there (to a host file the page wanted posted) is never followed. A runner that
  # said "ok" and left no image is a failed shot, never a silent success.
  defp collect(shot, out_file) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(shot),
         {:ok, data} <- File.read(shot) do
      File.write!(out_file, data)
      :ok
    else
      _ -> {:error, {:shot, "the capture runner reported success but left no image"}}
    end
  end
end
