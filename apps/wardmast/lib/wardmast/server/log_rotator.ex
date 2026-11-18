defmodule Wardmast.Server.LogRotator do
  @moduledoc """
  In-server, size-capped rotation of the server log (`~/.wardmast/log/wardmast.log`).

  On macOS launchd opens the log (`StandardOutPath`) and hands the descriptor to
  the server, so the file cannot be renamed away (the launchd-held fd would keep
  following the renamed inode) and there is no logrotate timer. This rotates by
  **copytruncate**: copy the live file to `<log>.1` (shifting `.1`→`.2`… and
  dropping the oldest), then truncate the original in place. The writer's fd stays
  valid; launchd opens with `O_APPEND`, so its next write lands at the new end of
  the (now empty) file. Lines written between the copy and the truncate are lost —
  the inherent copytruncate trade-off.

  Config (`config :wardmast, :log_rotation`): `:enabled` (default `true` on macOS only — Linux
  installs already rotate via the systemd logrotate timer; `false` in test), `:interval_ms` (default 60 000), `:max_bytes` (default 10 MiB),
  `:keep` (rotated files retained, default 5), `:path` (default
  `Wardmast.Config.Paths.server_log_path/0`).
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000
  @default_max_bytes 10 * 1024 * 1024
  @default_keep 5

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Rotate `path` when it is at least `:max_bytes` (default #{@default_max_bytes}) long.
  Returns `:rotated`, `:ok` (under the cap or absent) or `{:error, reason}`.
  """
  @spec rotate(String.t(), keyword()) :: :rotated | :ok | {:error, term()}
  def rotate(path, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    keep = max(Keyword.get(opts, :keep, @default_keep), 1)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size >= max_bytes ->
        copytruncate(path, keep)

      _ ->
        :ok
    end
  end

  defp copytruncate(path, keep) do
    shift(path, keep)

    with {:ok, _} <- File.copy(path, path <> ".1"),
         # Opening with :write truncates in place — same inode, so the launchd-owned
         # fd keeps working.
         {:ok, io} <- File.open(path, [:write]),
         :ok <- File.close(io) do
      :rotated
    end
  end

  defp shift(path, keep) do
    _ = File.rm(path <> ".#{keep}")

    for n <- (keep - 1)..1//-1, File.exists?(path <> ".#{n}") do
      File.rename(path <> ".#{n}", path <> ".#{n + 1}")
    end

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg(:enabled, opts, match?({:unix, :darwin}, :os.type())),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      opts: [
        path: cfg(:path, opts, nil),
        max_bytes: cfg(:max_bytes, opts, @default_max_bytes),
        keep: cfg(:keep, opts, @default_keep)
      ]
    }

    if state.enabled, do: Process.send_after(self(), :tick, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    path = state.opts[:path] || Wardmast.Config.Paths.server_log_path()

    case rotate(path, state.opts) do
      {:error, reason} -> Logger.warning("log rotation of #{path} failed: #{inspect(reason)}")
      _ -> :ok
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, v} -> v
      :error -> Keyword.get(Application.get_env(:wardmast, :log_rotation, []), key, default)
    end
  end
end
