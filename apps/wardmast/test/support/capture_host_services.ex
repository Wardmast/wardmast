defmodule Wardmast.Test.CaptureHostServices do
  @moduledoc """
  A `Wardmast.Screenshots.Capture.Services` for the real-bwrap capture test (bd-3glf2a), where
  podman is not available: each service is a listening Unix socket on the host, in a fresh `0700`
  directory under the socket root, exactly the endpoint `Services.Podman` hands the sandbox
  (there, a bridge into the container's own network namespace). Every connection gets
  `SERVICE <name> OK`. The directory also holds `other.sock`, which the app must never see.

  `context.opts`: `:test_pid` (told `{:host_services, role, dir}` and `{:host_services_stopped,
  dir}`), `:dir` (the directory is `<dir>-<role>`; default a random one under the socket root).
  """

  @behaviour Wardmast.Screenshots.Capture.Services

  alias Wardmast.Config.Paths

  @impl true
  def start(services, %{role: role, opts: opts}) do
    dir =
      case Keyword.get(opts, :dir) do
        nil ->
          Path.join(
            Paths.socket_root(),
            "svct-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
          )

        base ->
          "#{base}-#{role}"
      end

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    File.write!(Path.join(dir, "other.sock"), "")

    serving =
      for svc <- services do
        path = Path.join(dir, svc.name)
        {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
        pid = spawn(fn -> serve(listener, svc.name) end)
        :ok = :gen_tcp.controlling_process(listener, pid)
        {svc, path, pid}
      end

    test_pid = Keyword.get(opts, :test_pid)
    if test_pid, do: send(test_pid, {:host_services, role, dir})

    {:ok,
     %{
       endpoints:
         for(
           {svc, path, _} <- serving,
           do: %{name: svc.name, port: svc.port, socket: path, sandbox_socket: svc.socket}
         ),
       handle: %{dir: dir, pids: Enum.map(serving, &elem(&1, 2)), test_pid: test_pid}
     }}
  end

  @impl true
  def stop(%{handle: %{dir: dir, pids: pids, test_pid: test_pid}}) do
    Enum.each(pids, &Process.exit(&1, :kill))
    File.rm_rf(dir)
    if test_pid, do: send(test_pid, {:host_services_stopped, dir})
    :ok
  end

  defp serve(listener, name) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :gen_tcp.send(conn, "SERVICE #{name} OK\n")
        :gen_tcp.close(conn)
        serve(listener, name)

      {:error, _} ->
        :ok
    end
  end
end
