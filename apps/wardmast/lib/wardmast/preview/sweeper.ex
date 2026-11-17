defmodule Wardmast.Preview.Sweeper do
  @moduledoc """
  Runs `Wardmast.Preview.sweep/0` on a timer: the lifecycle backstop that stops
  previews whose ticket closed or merged, whose worktree was removed, or that
  sat idle past their TTL, and fails rows a restart orphaned.
  """

  use GenServer

  require Logger

  @interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    # First pass soon after boot: reconciles rows the previous VM left behind.
    Process.send_after(self(), :sweep, 5_000)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      Wardmast.Preview.sweep()
    rescue
      e -> Logger.warning("Preview.Sweeper: sweep failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
