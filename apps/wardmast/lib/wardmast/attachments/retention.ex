defmodule Wardmast.Attachments.Retention do
  @moduledoc """
  Runs the attachment retention sweeps on a timer: `Wardmast.Attachments.prune_expired/1`
  (closed tickets' blobs past their retention window) and
  `Wardmast.Attachments.sweep_orphans/0` (rows and blobs of tickets that no longer
  exist).

  Via `config :wardmast, :attachments_retention`: `:enabled` (default `true`;
  `false` in test, where tests drive `sweep/1` synchronously) and `:interval_ms`
  (default one hour).
  """

  use GenServer

  require Logger

  alias Wardmast.Attachments

  @default_interval_ms 60 * 60_000

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  One sweep. Best-effort: a failure is logged and swallowed, never raised into
  the caller. Returns `%{pruned: n, purged: n}`.
  """
  @spec sweep(keyword()) :: %{pruned: non_neg_integer(), purged: non_neg_integer()}
  def sweep(opts \\ []) do
    %{pruned: pruned} = Attachments.prune_expired(opts)
    %{purged: purged} = Attachments.sweep_orphans()
    %{pruned: pruned, purged: purged}
  rescue
    e ->
      Logger.error("Wardmast.Attachments.Retention sweep failed: #{Exception.message(e)}")
      %{pruned: 0, purged: 0}
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: Process.send_after(self(), :sweep, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        :wardmast |> Application.get_env(:attachments_retention, []) |> Keyword.get(key, default)
    end
  end
end
