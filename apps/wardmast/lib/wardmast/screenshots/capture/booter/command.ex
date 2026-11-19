defmodule Wardmast.Screenshots.Capture.Booter.Command do
  @moduledoc """
  The real `Wardmast.Screenshots.Capture.Booter`: runs the configured commands in the extracted
  source tree, inside the capture's sandbox, and waits for the app to answer.

  Per boot, in order: `setup_cmd`, `seed_cmd`, the named seed's command (when a shot asked for
  one), then `start_cmd` (long-running) until `ready.path` answers (`below_500` or `2xx`).
  Each setup/seed command is bounded by `limits.setup_seconds` / `limits.seed_seconds`, the
  readiness wait by `ready.timeout_seconds`.

  Every command runs in `spec.sandbox` (a `Wardmast.Screenshots.Capture.Sandbox`; in production
  `Sandbox.Bwrap`: no network, and of the host only its system directories, the checkout, the
  boot's scratch and any `sandbox.readonly_paths`), under
  `Wardmast.Screenshots.Capture.AppProcess`, with an environment built from nothing: `PATH`,
  `HOME` (`<scratch>/home`), `LANG`, `TMPDIR` (the boot's scratch dir), `TZ`, the config's `env`
  and the port variable. The operator's own environment (database URLs, provider and forge
  credentials, proxies) is never inherited. A spec without a sandbox runs nothing
  (`{:error, {:start, _}}`): there is no unsandboxed boot. Templates `{{port}}`, `{{role}}`,
  `{{scratch}}`, `{{checkout}}`, `{{task_id}}` are rendered in commands, `env` values and
  `base_url`.

  The app listens on `127.0.0.1:<port>` (`port` picked from `port_range`) inside the sandbox,
  which makes it reachable (`expose/2`); the readiness probe goes through the sandbox's `reach/1`
  and never reads a response body. The boot result carries the exposed `app`, which the shooter
  needs to give the browser its way to it.
  """

  @behaviour Wardmast.Screenshots.Capture.Booter

  alias Wardmast.Screenshots.Capture.AppProcess
  alias Wardmast.Screenshots.Capture.Sandbox

  @probe_ms 250

  @impl true
  def boot(spec) do
    cfg = spec.config

    with {:ok, sandbox} <- sandbox(spec),
         {:ok, port} <- free_port(cfg.port_range),
         {:ok, home} <- home(spec) do
      vars = %{
        "port" => port,
        "role" => spec.role,
        "scratch" => spec.scratch,
        "checkout" => spec.checkout,
        "task_id" => spec.task_id
      }

      run = %{
        sandbox: sandbox,
        box: %{
          checkout: spec.checkout,
          scratch: spec.scratch,
          readonly_paths: readonly_paths(cfg),
          # bd-3glf2a: the boot's services (reached on 127.0.0.1:<port> inside) and the offline
          # deps cache (shown read-only).
          services: Map.get(spec, :services) || [],
          cache_dirs: deps_dirs(spec)
        },
        checkout: spec.checkout,
        vars: vars,
        env: build_env(cfg, home, spec, vars, port)
      }

      limits = cfg.limits

      with :ok <- link_deps(spec),
           :ok <- run_once(run, :setup, cfg.setup_cmd, limits["setup_seconds"] || 600),
           :ok <- run_once(run, :seed, cfg.seed_cmd, limits["seed_seconds"] || 120),
           :ok <-
             run_once(run, :seed, named_seed(cfg, spec.seed), limits["seed_seconds"] || 120) do
        start_app(run, cfg, port)
      end
    end
  end

  @impl true
  def stop(_spec, %{process: process} = handle) do
    AppProcess.stop(process)

    case handle do
      %{sandbox: sandbox, exposed: exposed} -> sandbox.release(exposed)
      _ -> :ok
    end

    :ok
  end

  defp sandbox(%{sandbox: sandbox}) when is_atom(sandbox) and not is_nil(sandbox),
    do: {:ok, sandbox}

  defp sandbox(_spec),
    do:
      {:error, {:start, "no capture sandbox was given, and the app is never booted unsandboxed"}}

  defp home(spec) do
    home = Path.join(spec.scratch, "home")

    case File.mkdir_p(home) do
      :ok ->
        {:ok, home}

      {:error, reason} ->
        {:error,
         {:setup, "could not create the app's HOME #{home}: #{:file.format_error(reason)}"}}
    end
  end

  defp readonly_paths(cfg) do
    case Map.get(cfg, :sandbox) do
      %{"readonly_paths" => paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  # bd-3glf2a: the offline deps cache (`Capture.DepsCache`), when the capture built one.
  defp deps_dirs(%{deps: %{dir: dir}}) when is_binary(dir), do: [dir]
  defp deps_dirs(_spec), do: []

  defp deps_env(%{deps: %{env: env}}) when is_list(env), do: env
  defp deps_env(_spec), do: []

  # The cache's asset tools (esbuild, tailwind) linked where a stock Phoenix config looks for them,
  # `_build/<tool>-<target>` of the checkout: the link resolves inside the sandbox, where the cache
  # is shown at its own path.
  defp link_deps(%{deps: %{links: [_ | _] = links}, checkout: checkout}) do
    # The checkout is the worker's tree: a `_build` it committed as a link is never followed on
    # the host.
    case File.lstat(Path.join(checkout, "_build")) do
      {:ok, %File.Stat{type: type}} when type != :directory ->
        {:error,
         {:setup,
          "the checkout's _build is a #{type}, not a directory, so the deps cache's asset " <>
            "tools are not linked through it"}}

      _ ->
        link_tools(links, checkout)
    end
  end

  defp link_deps(_spec), do: :ok

  defp link_tools(links, checkout) do
    Enum.reduce_while(links, :ok, fn {rel, target}, :ok ->
      link = Path.join(checkout, rel)

      result =
        with :ok <- File.mkdir_p(Path.dirname(link)) do
          if match?({:ok, _}, File.lstat(link)), do: :ok, else: File.ln_s(target, link)
        end

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            {:setup, "could not link #{rel} to the deps cache: #{:file.format_error(reason)}"}}}
      end
    end)
  end

  defp named_seed(_cfg, nil), do: nil
  defp named_seed(cfg, seed), do: Map.get(cfg.seeds, seed)

  defp run_once(_run, _phase, nil, _timeout_s), do: :ok

  defp run_once(run, phase, command, timeout_s) do
    case start(run, command, nil) do
      {:ok, process} ->
        try do
          case AppProcess.await_exit(process, timeout_s * 1000) do
            {:exited, 0, _tail} ->
              :ok

            {:exited, code, tail} ->
              {:error, {phase, "`#{command}` exited with status #{code}: #{tail}"}}

            {:timeout, tail} ->
              {:error, {phase, "`#{command}` did not finish in #{timeout_s} s: #{tail}"}}
          end
        after
          AppProcess.stop(process)
        end

      {:error, reason} ->
        {:error, {phase, "the capture sandbox could not run `#{command}`: #{why(run, reason)}"}}
    end
  end

  # `command` wrapped by the sandbox, run with exactly the boot's environment.
  defp start(run, command, exposed) do
    argv = [System.find_executable("sh") || "/bin/sh", "-c", render(command, run.vars)]

    with {:ok, boxed} <- run.sandbox.command(argv, run.box, exposed) do
      AppProcess.start_link(%{argv: boxed, cd: run.checkout, env: run.env})
    end
  end

  defp start_app(_run, %{start_cmd: nil}, _port),
    do: {:error, {:start, "no start_cmd is configured"}}

  defp start_app(run, cfg, port) do
    with {:ok, exposed} <- expose(run, port),
         {:ok, process} <- start_exposed(run, cfg.start_cmd, exposed) do
      base_url = String.trim_trailing(render(cfg.base_url, run.vars), "/")

      case wait_ready(process, base_url, cfg.ready, run.sandbox.reach(exposed)) do
        :ok ->
          {:ok,
           %{
             handle: %{process: process, sandbox: run.sandbox, exposed: exposed},
             base_url: base_url,
             app: exposed
           }}

        {:error, _} = error ->
          AppProcess.stop(process)
          run.sandbox.release(exposed)
          error
      end
    end
  end

  defp expose(run, port) do
    case run.sandbox.expose(run.box, port) do
      {:ok, exposed} ->
        {:ok, exposed}

      {:error, reason} ->
        {:error, {:start, "the capture sandbox could not expose the app: #{why(run, reason)}"}}
    end
  end

  defp start_exposed(run, command, exposed) do
    case start(run, command, exposed) do
      {:ok, process} ->
        {:ok, process}

      {:error, reason} ->
        run.sandbox.release(exposed)
        {:error, {:start, "the capture sandbox could not run `#{command}`: #{why(run, reason)}"}}
    end
  end

  defp why(run, reason) do
    run.sandbox.describe(reason)
  rescue
    _ -> inspect(reason)
  end

  defp wait_ready(process, base_url, ready, reach) do
    timeout_s = ready["timeout_seconds"] || 120
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1000
    url = base_url <> (ready["path"] || "/")
    do_wait(process, url, ready["expect"] || "below_500", {deadline, timeout_s}, reach)
  end

  defp do_wait(process, url, expect, {deadline, timeout_s} = limit, reach) do
    case AppProcess.status(process) do
      {{:exited, code}, tail} ->
        {:error, {:start, "the app exited with status #{code} before it was ready: #{tail}"}}

      {:running, tail} ->
        case probe(url, expect, reach) do
          :ready ->
            :ok

          {:not_ready, detail} ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error,
               {:ready, "not ready after #{timeout_s} s (GET #{url}: #{detail}): #{tail}"}}
            else
              Process.sleep(@probe_ms)
              do_wait(process, url, expect, limit, reach)
            end
        end
    end
  end

  defp probe(url, expect, reach) do
    opts =
      [retry: false, redirect: false, receive_timeout: 3_000, request_timeout: 5_000] ++
        [into: &status_only/2] ++ reach

    case Req.get(url, opts) do
      {:ok, %{status: status}} ->
        if ready_status?(status, expect), do: :ready, else: {:not_ready, "status #{status}"}

      {:error, exception} ->
        {:not_ready, Exception.message(exception)}
    end
  end

  # Only the status matters: an untrusted app's body is never read into the server, and
  # `request_timeout` bounds the whole exchange, so a trickled answer cannot hold a probe open
  # past the readiness deadline either.
  defp status_only({:data, _chunk}, acc), do: {:halt, acc}

  defp ready_status?(status, "2xx"), do: status in 200..299
  defp ready_status?(status, _below_500), do: status < 500

  # ── environment, ports, templates ───────────────────────────────────────

  defp build_env(cfg, home, spec, vars, port) do
    base =
      [
        {"PATH", Sandbox.path()},
        {"HOME", home},
        {"LANG", "C.UTF-8"},
        {"TMPDIR", spec.scratch},
        {"TZ", "UTC"}
      ]

    configured = Enum.map(cfg.env, fn {k, v} -> {k, render(v, vars)} end)

    # The deps cache's variables come after the config's (`env -i` keeps the last of a name), so
    # a hand-set MIX_HOME cannot point the boot away from it.
    base ++ configured ++ deps_env(spec) ++ [{cfg.port_env, Integer.to_string(port)}]
  end

  defp free_port({lo, hi}) do
    lo..hi
    |> Enum.shuffle()
    |> Enum.find(&free?/1)
    |> case do
      nil -> {:error, {:start, "no free port in #{lo}-#{hi}"}}
      port -> {:ok, port}
    end
  end

  defp free?(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp render(template, vars) do
    Regex.replace(~r/\{\{\s*([a-z_]+)\s*\}\}/, template, fn whole, name ->
      case Map.fetch(vars, name) do
        {:ok, value} -> to_string(value)
        :error -> whole
      end
    end)
  end
end
