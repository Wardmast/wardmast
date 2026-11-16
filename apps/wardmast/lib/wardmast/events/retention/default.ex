defmodule Wardmast.Events.Retention.Default do
  @moduledoc """
  Default `Wardmast.Events.Retention.Policy`: prune rows older than
  `:retention_days` (sweep option, else `config :wardmast, :events_retention`,
  else 7).
  """

  @behaviour Wardmast.Events.Retention.Policy

  @default_retention_days 7

  @impl true
  def cutoff(now, opts) do
    days =
      Keyword.get_lazy(opts, :retention_days, fn ->
        Wardmast.Events.Retention.config(:retention_days, @default_retention_days)
      end)

    DateTime.add(now, -days, :day)
  end
end
