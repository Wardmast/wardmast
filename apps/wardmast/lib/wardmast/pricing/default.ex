defmodule Wardmast.Pricing.Default do
  @moduledoc "Core's built-in price tables behind the `Wardmast.Pricing` behaviour."

  @behaviour Wardmast.Pricing

  alias Wardmast.Agents.Gemini.Pricing, as: GeminiPricing
  alias Wardmast.Usage.ClaudePricing

  @impl true
  def cost_usd(:claude, model, buckets) when is_map(buckets),
    do: ClaudePricing.cost_usd(model, buckets)

  def cost_usd(:gemini, _model, stats), do: GeminiPricing.cost_usd(stats)
  def cost_usd(_provider, _model, _usage), do: nil
end
