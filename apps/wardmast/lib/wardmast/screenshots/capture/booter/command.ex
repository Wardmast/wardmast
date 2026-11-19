defmodule Wardmast.Screenshots.Capture.Booter.Command do
  @moduledoc """
  The real `Wardmast.Screenshots.Capture.Booter`: runs the configured commands in the extracted
  source tree and waits for the app to answer.

  Per boot, in order: `setup_cmd`, `seed_cmd`, the named seed's command (when a shot asked for
  one), then `start_cmd` (long-running) until `ready.path` answers (`below_500` or `2xx`).
  Each setup/seed command is bounded by `limits.setup_seconds` / `limits.seed_seconds`, the
  readiness wait by `ready.timeout_seconds`. Every command runs under
  `Wardmast.Screenshots.Capture.AppProcess` with an environment built from nothing: `PATH`,
  `HOME`, `LANG`, `TMPDIR` (the boot's scratch dir), the config's `env` and the port variable. The
  operator's own environment (database URLs, provider and forge credentials, proxies) is never
  inherited. Templates `{{port}}`, `{{role}}`, `{{scratch}}`, `{{checkout}}`, `{{task_id}}`
  are rendered in commands, `env` values and `base_url`.

  The port is a free one picked from `port_range` on this host. Isolating the boot from the host
  network is the pass's sandbox (pod, design §2), not this module's job.
  """

  @behaviour Wardmast.Screenshots.Capture.Booter

  alias Wardmast.Screenshots.Capture.AppProcess

  @probe_ms 250

  @impl true
  def boot(spec) do
    cfg = spec.config

    with {:ok, port} <- free_port(cfg.port_range) do
      vars = %{
        "port" => port,
        "role" => spec.role,
        "scratch" => spec.scratch,
        "checkout" => spec.checkout,
        "task_id" => spec.task_id
      }

      env = build_env(cfg, spec, vars, port)
      limits = cfg.limits

      with :ok <- run_once(:setup, cfg.setup_cmd, spec, vars, env, limits["setup_seconds"] || 600),
           :ok <- run_once(:seed, cfg.seed_cmd, spec, vars, env, limits["seed_seconds"] || 120),
           :ok <-
             run_once(
               :seed,
               named_seed(cfg, spec.seed),
               spec,
               vars,
               env,
               limits["seed_seconds"] || 120
             ) do
        start_app(cfg, spec, vars, env, port)
      end
    end
  end

  @impl true
  def stop(_spec, %{app: app}) do
    AppProcess.stop(app)
  end

  defp named_seed(_cfg, nil), do: nil
  defp named_seed(cfg, seed), do: Map.get(cfg.seeds, seed)

  defp run_once(_phase, nil, _spec, _vars, _env, _timeout_s), do: :ok

  defp run_once(phase, command, spec, vars, env, timeout_s) do
    {:ok, app} =
      AppProcess.start_link(%{command: render(command, vars), cd: spec.checkout, env: env})

    try do
      case AppProcess.await_exit(app, timeout_s * 1000) do
        {:exited, 0, _tail} ->
          :ok

        {:exited, code, tail} ->
          {:error, {phase, "`#{command}` exited with status #{code}: #{tail}"}}

        {:timeout, tail} ->
          {:error, {phase, "`#{command}` did not finish in #{timeout_s} s: #{tail}"}}
      end
    after
      AppProcess.stop(app)
    end
  end

  defp start_app(cfg, spec, vars, env, port) do
    case cfg.start_cmd do
      nil ->
        {:error, {:start, "no start_cmd is configured"}}

      command ->
        {:ok, app} =
          AppProcess.start_link(%{command: render(command, vars), cd: spec.checkout, env: env})

        base_url = String.trim_trailing(render(cfg.base_url, vars), "/")

        case wait_ready(app, base_url, cfg.ready) do
          :ok ->
            {:ok, %{handle: %{app: app, port: port}, base_url: base_url}}

          {:error, _} = error ->
            AppProcess.stop(app)
            error
        end
    end
  end

  defp wait_ready(app, base_url, ready) do
    timeout_s = ready["timeout_seconds"] || 120
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1000

    do_wait(
      app,
      base_url <> (ready["path"] || "/"),
      ready["expect"] || "below_500",
      deadline,
      timeout_s
    )
  end

  defp do_wait(app, url, expect, deadline, timeout_s) do
    case AppProcess.status(app) do
      {{:exited, code}, tail} ->
        {:error, {:start, "the app exited with status #{code} before it was ready: #{tail}"}}

      {:running, tail} ->
        case probe(url, expect) do
          :ready ->
            :ok

          {:not_ready, detail} ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error,
               {:ready, "not ready after #{timeout_s} s (GET #{url}: #{detail}): #{tail}"}}
            else
              Process.sleep(@probe_ms)
              do_wait(app, url, expect, deadline, timeout_s)
            end
        end
    end
  end

  defp probe(url, expect) do
    case Req.get(url,
           retry: false,
           redirect: false,
           receive_timeout: 3_000,
           connect_options: [timeout: 2_000]
         ) do
      {:ok, %{status: status}} ->
        if ready_status?(status, expect), do: :ready, else: {:not_ready, "status #{status}"}

      {:error, exception} ->
        {:not_ready, Exception.message(exception)}
    end
  end

  defp ready_status?(status, "2xx"), do: status in 200..299
  defp ready_status?(status, _below_500), do: status < 500

  # ── environment, ports, templates ───────────────────────────────────────

  defp build_env(cfg, spec, vars, port) do
    base =
      [
        {"PATH", System.get_env("PATH") || "/usr/local/bin:/usr/bin:/bin"},
        {"HOME", System.get_env("HOME") || spec.scratch},
        {"LANG", "C.UTF-8"},
        {"TMPDIR", spec.scratch},
        {"TZ", "UTC"}
      ]

    configured = Enum.map(cfg.env, fn {k, v} -> {k, render(v, vars)} end)
    base ++ configured ++ [{cfg.port_env, Integer.to_string(port)}]
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
