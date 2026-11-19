defmodule Wardmast.Test.CaptureFakeBridge do
  @moduledoc """
  A stand-in for `Wardmast.Screenshots.Capture.Services.Bridge` (bd-3glf2a) in tests that fake
  podman: instead of running `nsenter … socat`, it listens on the `UNIX-LISTEN:` path of the argv
  itself (so the host socket really exists) and greets each connection with `service`. It tells
  the test process what it was asked to run (`{:bridge_started, argv}`, `{:bridge_stopped, ref}`).

  `start/2` options: `:test_pid`, and `:dies` (the bridge exits at once, with that output).
  """

  @doc "The socket path a bridge argv listens on."
  @spec listen_path([String.t()]) :: String.t()
  def listen_path(argv) do
    Enum.find_value(argv, fn arg ->
      case Regex.run(~r/\AUNIX-LISTEN:([^,]+)/, arg) do
        [_, path] -> path
        _ -> nil
      end
    end)
  end

  @doc false
  def start(argv, opts) do
    test_pid = Keyword.get(opts, :test_pid)
    if test_pid, do: send(test_pid, {:bridge_started, argv})

    case Keyword.get(opts, :dies) do
      nil ->
        path = listen_path(argv)
        {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
        # Linked: it goes down with whoever started it, as the real bridge does.
        pid = spawn_link(fn -> serve(listener) end)
        :ok = :gen_tcp.controlling_process(listener, pid)
        {:ok, %{pid: pid, test_pid: test_pid, dies: nil}}

      output ->
        {:ok, %{pid: nil, test_pid: test_pid, dies: output}}
    end
  end

  @doc false
  def status(%{dies: nil}), do: :running
  def status(%{dies: output}), do: {:exited, output}

  @doc false
  def stop(%{pid: pid, test_pid: test_pid} = ref) do
    if pid do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    if test_pid, do: send(test_pid, {:bridge_stopped, ref})
    :ok
  end

  defp serve(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :gen_tcp.send(conn, "service\n")
        :gen_tcp.close(conn)
        serve(listener)

      {:error, _} ->
        :ok
    end
  end
end
