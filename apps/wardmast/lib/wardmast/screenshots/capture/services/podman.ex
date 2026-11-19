defmodule Wardmast.Screenshots.Capture.Services.Podman do
  @moduledoc """
  Capture services as podman containers (bd-3glf2a; the contract is
  `Wardmast.Screenshots.Capture.Services`, the design `docs/design/ui-screenshot-capture.md` §2).

  ## One service, one boot

      podman run -d --name arb-cap-<role>-<token>-<service> --network none --pull=missing \\
        --security-opt no-new-privileges --cap-drop all --cap-add <a root entrypoint's few> \\
        --log-driver k8s-file --label arbiter.capture-service=<server os pid> … \\
        -e <env> -- <image> <command>

  `--network none`: the container's namespace has only its own `lo`. Nothing is published on the
  host and nothing of the host is mounted into it. This matters more than it looks: the app can
  usually run code **inside** a service (a Postgres superuser's `COPY … FROM PROGRAM`), so the
  container is part of the sandbox and must have no way out either. A port published on the
  host's loopback was the alternative and is rejected: it needs a network the container could
  also leave by, and every process on the host could reach it.

  ## The bridge (no published port)

  The host reaches the service through its own namespace: a `socat` that `nsenter` puts into the
  container's network namespace (and, rootless, the user namespace that owns it, the way podman's
  own `pasta`/`slirp4netns` helpers join it) listens on a **Unix socket on the host**, in a fresh
  `0700` directory under `Wardmast.Config.Paths.socket_root/0`, and connects each client to
  `127.0.0.1:<port>` inside the container. The container cannot see that socket; it only answers
  the connections the bridge opens. `setpriv --pdeathsig KILL` (when present) takes the bridge
  down with the server. The capture sandbox then shows that socket to the app read-only and
  relays `127.0.0.1:<port>` to it (`Sandbox.Bwrap`), so the app reaches the service exactly
  there and nowhere else.

  ## Ready

  `ready.cmd` is `podman exec`ed in the container until it exits 0; `ready.tcp` (the default)
  connects to the port from inside the container's namespace (`socat -u OPEN:/dev/null
  TCP:127.0.0.1:<port>`). Both are bounded by `ready.timeout_seconds`; a container that stops
  meanwhile fails at once. Any failure returns the tail of `podman logs` and leaves nothing
  running.

  ## Removal

  Every container is removed by its exact name (`podman rm --force --ignore --time 0`): by
  `stop/1`, by `start/2` itself when a later service fails, and otherwise by
  `Wardmast.Screenshots.Capture.Services.Reaper` (its owner died, the server shut down, or at the
  next boot for a server that died hard). Each container is tracked there **before** it runs.

  ## Options (`context.opts`)

  `:runner` (`(cmd, args, opts -> {output, status})`, a stand-in for podman/nsenter, as
  `Wardmast.Worker.Container.cmd/4`), `:podman`, `:nsenter`, `:socat`, `:setpriv` (executables;
  `:path` is the `PATH` they are looked up on otherwise), `:rootless` (default: the server is not
  root), `:bridge` (default `Services.Bridge`) with `:bridge_opts`, `:ready_interval_ms` (500),
  `:reaper` (a server, or `false`; default the running `Services.Reaper`), `:server_pid`.
  """

  @behaviour Wardmast.Screenshots.Capture.Services

  alias Wardmast.Config.Paths
  alias Wardmast.Screenshots.Capture.Services.Bridge
  alias Wardmast.Screenshots.Capture.Services.Reaper
  alias Wardmast.Worker.Container

  @label "arbiter.capture-service"
  @name_prefix "arb-cap-"
  # What a root entrypoint needs to chown its data dir and drop to its own user (gosu, su-exec);
  # rootless, these hold only inside the container's user namespace.
  @caps ~w(CHOWN DAC_OVERRIDE FOWNER FSETID KILL NET_BIND_SERVICE SETGID SETUID)
  @run_timeout_ms 300_000
  @cmd_timeout_ms 30_000
  @socket_wait_ms 5_000
  @ready_interval_ms 500
  @log_lines 40
  @log_bytes 3_000
  @max_socket_path 100

  # ── the contract ────────────────────────────────────────────────────────

  @impl true
  def start([], _context), do: {:ok, %{endpoints: [], handle: nil}}

  def start(services, context) do
    opts = Map.get(context, :opts) || []

    with {:ok, tools} <- tools(opts),
         {:ok, dir} <- socket_dir() do
      run = %{
        tools: tools,
        opts: opts,
        dir: dir,
        role: Map.get(context, :role, "boot"),
        task: Map.get(context, :task_id),
        token: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        owner: self(),
        reaper: reaper(opts),
        rootless: Keyword.get_lazy(opts, :rootless, &rootless?/0),
        bridge: Keyword.get(opts, :bridge, Bridge),
        bridge_opts: Keyword.get(opts, :bridge_opts, []),
        interval: Keyword.get(opts, :ready_interval_ms, @ready_interval_ms)
      }

      track(run, {:dir, dir})
      start_all(run, services)
    end
  end

  @impl true
  def stop(%{handle: %{run: run, started: started}}) do
    cleanup(run, started)
    :ok
  end

  def stop(_running), do: :ok

  # ── start ───────────────────────────────────────────────────────────────

  defp start_all(run, services) do
    services
    |> Enum.reduce_while({:ok, []}, fn svc, {:ok, started} ->
      case start_one(run, svc) do
        {:ok, one} -> {:cont, {:ok, [one | started]}}
        {:error, failure, one} -> {:halt, {:error, failure, [one | started]}}
      end
    end)
    |> case do
      {:ok, started} ->
        started = Enum.reverse(started)
        {:ok, %{endpoints: Enum.map(started, &endpoint/1), handle: %{run: run, started: started}}}

      {:error, failure, started} ->
        cleanup(run, started)
        {:error, failure}
    end
  end

  defp endpoint(one),
    do: %{
      name: one.service.name,
      port: one.service.port,
      socket: one.socket,
      sandbox_socket: one.service.socket
    }

  defp start_one(run, svc) do
    one = %{
      service: svc,
      name: @name_prefix <> "#{run.role}-#{run.token}-#{svc.name}",
      socket: Path.join(run.dir, svc.name),
      bridge: nil
    }

    # Tracked before it exists: a capture killed between `run` and the bookkeeping cannot leak it.
    track(run, {:container, one.name, podman_opts(run)})

    # Once the bridge runs, every failure must hand back the `one` that holds it, or it would
    # never be stopped.
    with :ok <- podman_run(run, one),
         {:ok, pid} <- container_pid(run, one),
         {:ok, bridged} <- start_bridge(run, one, pid) do
      case await_ready(run, bridged, pid) do
        :ok -> {:ok, bridged}
        {:error, reason} -> {:error, failure(run, bridged, reason), bridged}
      end
    else
      {:error, reason} -> {:error, failure(run, one, reason), one}
      {:error, reason, bridged} -> {:error, failure(run, bridged, reason), bridged}
    end
  end

  defp failure(run, one, reason),
    do: %{service: one.service.name, reason: reason, log_tail: logs(run, one.name)}

  defp podman_run(run, one) do
    labels = [
      {@label, Keyword.get(run.opts, :server_pid, System.pid())},
      {"arbiter.capture-task", run.task || "-"},
      {"arbiter.capture-role", run.role}
    ]

    case cmd(run, [run.tools.podman | run_args(one.name, one.service, labels)], @run_timeout_ms) do
      {_, 0} ->
        :ok

      {out, status} ->
        {:error, "podman could not start its container (exit #{status}): #{tail(out, 500)}"}
    end
  end

  @doc false
  @spec run_args(String.t(), map(), [{String.t(), term()}]) :: [String.t()]
  def run_args(name, svc, labels) do
    Enum.concat([
      ["run", "-d", "--name", name, "--network", "none", "--pull=missing"],
      ["--security-opt", "no-new-privileges", "--cap-drop", "all"],
      Enum.flat_map(@caps, &["--cap-add", &1]),
      ["--log-driver", "k8s-file"],
      Enum.flat_map(labels, fn {k, v} -> ["--label", "#{k}=#{v}"] end),
      Enum.flat_map(svc.env, fn {k, v} -> ["-e", "#{k}=#{v}"] end),
      ["--", svc.image | svc.command]
    ])
  end

  defp container_pid(run, one) do
    case cmd(run, [run.tools.podman, "inspect", "--format", "{{.State.Pid}}", one.name]) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _ -> {:error, "its container exited as it started"}
        end

      {out, status} ->
        {:error, "podman inspect failed (exit #{status}): #{tail(out, 500)}"}
    end
  end

  defp start_bridge(run, one, pid) do
    listen = "UNIX-LISTEN:#{one.socket},fork,mode=0600"
    argv = in_netns(run, pid, [run.tools.socat, listen, "TCP:127.0.0.1:#{one.service.port}"])

    case run.bridge.start(argv, run.bridge_opts) do
      {:ok, ref} ->
        one = %{one | bridge: ref}
        deadline = System.monotonic_time(:millisecond) + @socket_wait_ms

        case await_socket(run, one, deadline) do
          :ok -> {:ok, one}
          {:error, reason} -> {:error, reason, one}
        end

      {:error, reason} ->
        {:error, "could not start the bridge into its namespace: #{inspect(reason)}"}
    end
  end

  # `argv` inside the container's network namespace (and, rootless, the user namespace that owns
  # it), killed with the server.
  @doc false
  @spec in_netns(map(), pos_integer(), [String.t()]) :: [String.t()]
  def in_netns(run, pid, argv) do
    t = run.tools
    prefix = if t.setpriv, do: [t.setpriv, "--pdeathsig", "KILL", "--"], else: []
    userns = if run.rootless, do: ["--user", "--preserve-credentials"], else: []
    prefix ++ [t.nsenter, "--target", Integer.to_string(pid)] ++ userns ++ ["--net", "--" | argv]
  end

  defp await_socket(run, one, deadline) do
    cond do
      match?({:ok, %File.Stat{type: :other}}, File.lstat(one.socket)) ->
        :ok

      match?({:exited, _}, run.bridge.status(one.bridge)) ->
        {:exited, out} = run.bridge.status(one.bridge)
        {:error, "the bridge into its network namespace exited: #{tail(out, 500)}"}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "the bridge into its network namespace did not come up"}

      true ->
        Process.sleep(20)
        await_socket(run, one, deadline)
    end
  end

  defp await_ready(run, one, pid) do
    ready = one.service.ready
    deadline = System.monotonic_time(:millisecond) + ready.timeout_seconds * 1000
    poll(run, one, pid, deadline)
  end

  defp poll(run, one, pid, deadline) do
    case check_ready(run, one, pid, deadline) do
      :ok ->
        :ok

      {:not_ready, detail} ->
        cond do
          not running?(run, one) ->
            {:error, "its container exited before it was ready (last check: #{detail})"}

          match?({:exited, _}, run.bridge.status(one.bridge)) ->
            {:error, "the bridge into its network namespace exited before it was ready"}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             "did not become ready in #{one.service.ready.timeout_seconds} s " <>
               "(last check: #{detail})"}

          true ->
            if run.interval > 0, do: Process.sleep(run.interval)
            poll(run, one, pid, deadline)
        end
    end
  end

  defp check_ready(run, one, pid, deadline) do
    timeout = max(1_000, min(@cmd_timeout_ms, deadline - System.monotonic_time(:millisecond)))

    argv =
      case one.service.ready do
        %{kind: :cmd, cmd: ready} ->
          [run.tools.podman, "exec", one.name | ready]

        %{kind: :tcp} ->
          probe = "TCP:127.0.0.1:#{one.service.port},connect-timeout=2"
          in_netns(run, pid, [run.tools.socat, "-u", "OPEN:/dev/null", probe])
      end

    case cmd(run, argv, timeout) do
      {_, 0} -> :ok
      {out, status} -> {:not_ready, last_line(out, status)}
    end
  end

  defp running?(run, one) do
    case cmd(run, [run.tools.podman, "inspect", "--format", "{{.State.Status}}", one.name]) do
      {out, 0} -> String.trim(out) == "running"
      _ -> false
    end
  end

  defp logs(run, name) do
    args = ["logs", "--tail", Integer.to_string(@log_lines), name]

    case cmd(run, [run.tools.podman | args]) do
      {out, 0} -> tail(out, @log_bytes)
      _ -> nil
    end
  end

  # ── removal ─────────────────────────────────────────────────────────────

  defp cleanup(run, started) do
    Enum.each(started, fn one ->
      if one.bridge, do: run.bridge.stop(one.bridge)
      _ = remove(one.name, podman_opts(run))
      untrack(run, {:container, one.name, podman_opts(run)})
    end)

    _ = File.rm_rf(run.dir)
    untrack(run, {:dir, run.dir})
  end

  @doc """
  `podman rm --force --ignore --time 0 <name>`: removes the container whether it runs, stopped
  or is gone. Refuses a name this module would not have made. Options: `:runner`, `:podman`.
  """
  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(name, opts) do
    if String.starts_with?(name, @name_prefix) do
      podman = Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"
      args = ["rm", "--force", "--ignore", "--time", "0", name]

      case Container.cmd(opts, podman, args, timeout: @cmd_timeout_ms) do
        {_, 0} -> :ok
        {out, status} -> {:error, {:podman_rm_failed, status, String.trim(out)}}
      end
    else
      {:error, {:not_a_capture_service, name}}
    end
  end

  @doc """
  Remove the service containers a dead server left behind: every container labelled
  `arbiter.capture-service=<os pid>` (and named `arb-cap-…`) whose server is not alive. Never
  one of this server or of another live one. Returns the names removed. Options: `:runner`,
  `:podman`, `:alive?` (`(os_pid -> boolean)`).
  """
  @spec reap_orphans(keyword()) :: [String.t()]
  def reap_orphans(opts \\ []) do
    podman = Keyword.get(opts, :podman) || System.find_executable("podman")
    alive? = Keyword.get(opts, :alive?, &os_alive?/1)
    args = ["ps", "-a", "--filter", "label=#{@label}", "--format", "json"]

    with podman when is_binary(podman) <- podman,
         {out, 0} <- Container.cmd(opts, podman, args, timeout: @cmd_timeout_ms),
         {:ok, list} when is_list(list) <- Jason.decode(out) do
      list
      |> Enum.flat_map(&orphan(&1, alive?))
      |> Enum.filter(&(remove(&1, Keyword.put(opts, :podman, podman)) == :ok))
    else
      _ -> []
    end
  end

  defp orphan(%{"Names" => [name | _], "Labels" => %{@label => pid}}, alive?)
       when is_binary(name) do
    if String.starts_with?(name, @name_prefix) and not alive?.(pid), do: [name], else: []
  end

  defp orphan(_container, _alive?), do: []

  defp os_alive?(pid) when is_binary(pid) do
    pid == System.pid() or
      (String.match?(pid, ~r/\A\d+\z/) and
         match?({_, 0}, System.cmd("ps", ["-p", pid, "-o", "pid="], stderr_to_stdout: true)))
  rescue
    ErlangError -> false
  end

  defp os_alive?(_), do: false

  # ── helpers ─────────────────────────────────────────────────────────────

  defp tools(opts) do
    path = Keyword.get(opts, :path)

    with {:ok, podman} <- tool(opts, :podman, path),
         {:ok, nsenter} <- tool(opts, :nsenter, path),
         {:ok, socat} <- tool(opts, :socat, path) do
      setpriv =
        if Keyword.has_key?(opts, :setpriv),
          do: Keyword.get(opts, :setpriv),
          else: find(Atom.to_string(:setpriv), path)

      {:ok, %{podman: podman, nsenter: nsenter, socat: socat, setpriv: setpriv}}
    end
  end

  defp tool(opts, key, path) do
    case Keyword.get(opts, key) || find(Atom.to_string(key), path) do
      nil ->
        {:error,
         %{
           service: nil,
           reason:
             "#{key} is not installed on this host, and capture services need it (podman " <>
               "runs them, nsenter and socat bridge to them)",
           log_tail: nil
         }}

      exe ->
        {:ok, exe}
    end
  end

  defp find(name, nil), do: System.find_executable(name)

  defp find(name, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&File.regular?/1)
  end

  # A fresh 0700 directory for this boot's sockets, outside every sandbox.
  defp socket_dir do
    root = Paths.socket_root()
    dir = Path.join(root, "svc-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower))

    with true <- byte_size(dir) + 17 <= @max_socket_path or {:error, :socket_path_too_long},
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      {:error, reason} ->
        {:error,
         %{
           service: nil,
           reason:
             "could not make the services' socket directory under #{root}: #{inspect(reason)}",
           log_tail: nil
         }}
    end
  end

  defp reaper(opts) do
    case Keyword.fetch(opts, :reaper) do
      {:ok, false} -> nil
      {:ok, server} -> server
      :error -> if Process.whereis(Reaper), do: Reaper, else: nil
    end
  end

  defp track(%{reaper: nil}, _item), do: :ok
  defp track(run, item), do: Reaper.track(run.reaper, run.owner, item)

  defp untrack(%{reaper: nil}, _item), do: :ok
  defp untrack(run, item), do: Reaper.untrack(run.reaper, run.owner, item)

  defp podman_opts(run), do: [podman: run.tools.podman] ++ Keyword.take(run.opts, [:runner])

  # Root runs podman rootful: the containers then share the host's user namespace.
  defp rootless? do
    case File.read("/proc/self/status") do
      {:ok, status} ->
        case Regex.run(~r/^Uid:\s+\d+\s+(\d+)/m, status) do
          [_, "0"] -> false
          _ -> true
        end

      _ ->
        true
    end
  end

  defp cmd(run, [exe | args], timeout \\ @cmd_timeout_ms),
    do: Container.cmd(run.opts, exe, args, timeout: timeout)

  defp last_line(out, status) do
    case out |> String.trim() |> String.split("\n") |> List.last() do
      line when line in [nil, ""] -> "exit #{status}"
      line -> String.slice(line, 0, 300)
    end
  end

  defp tail(out, bytes) do
    out = String.trim(out)
    if byte_size(out) <= bytes, do: out, else: binary_part(out, byte_size(out) - bytes, bytes)
  end
end
