defmodule Wardmast.Screenshots.Capture.Services.Bridge do
  @moduledoc """
  The long-running half of a capture service's bridge (bd-3glf2a): the `nsenter … socat` process
  `Wardmast.Screenshots.Capture.Services.Podman` builds, owned by a
  `Wardmast.Screenshots.Capture.AppProcess` (its own process group, an environment built from
  nothing, killed on `stop/1` or when the process that started it dies).

  `Services.Podman` takes the module as `:bridge`, so tests swap in a stand-in with the same three
  functions.
  """

  alias Wardmast.Screenshots.Capture.AppProcess

  @doc "Start `argv` (executable first). `opts` is unused here."
  @spec start([String.t()], keyword()) :: {:ok, pid()} | {:error, term()}
  def start(argv, _opts \\ []),
    do: AppProcess.start_link(%{argv: argv, cd: "/", env: [{"LANG", "C.UTF-8"}]})

  @doc "`:running`, or `{:exited, output}` once it has gone."
  @spec status(pid()) :: :running | {:exited, String.t()}
  def status(pid) do
    case AppProcess.status(pid) do
      {:running, _tail} -> :running
      {{:exited, code}, tail} -> {:exited, "exit #{code}: #{String.trim(tail)}"}
    end
  catch
    :exit, _ -> {:exited, "the bridge process is gone"}
  end

  @doc "Kill it (its whole process group). Always `:ok`."
  @spec stop(pid()) :: :ok
  def stop(pid), do: AppProcess.stop(pid)
end
