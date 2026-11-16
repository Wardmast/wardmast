defmodule Wardmast.PricingTest do
  use ExUnit.Case, async: false

  alias Wardmast.Agents.Gemini.Pricing, as: GeminiPricing
  alias Wardmast.Pricing
  alias Wardmast.Usage.ClaudePricing

  defmodule Flat do
    @behaviour Wardmast.Pricing
    @impl true
    def cost_usd(_provider, _model, _usage), do: 42.0
  end

  defmodule Boom do
    @behaviour Wardmast.Pricing
    @impl true
    def cost_usd(_provider, _model, _usage), do: raise("boom")
  end

  setup do
    prev = Application.get_env(:wardmast, :pricing)
    on_exit(fn -> restore(prev) end)
    Application.delete_env(:wardmast, :pricing)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:wardmast, :pricing)
  defp restore(v), do: Application.put_env(:wardmast, :pricing, v)

  @buckets %{tokens_in: 1000, tokens_out: 500}
  @stats %{
    "models" => %{"gemini-2.5-pro" => %{"tokens" => %{"input" => 1000, "candidates" => 10}}}
  }

  test "default matches the per-provider tables" do
    model = ClaudePricing.price_table() |> Map.keys() |> hd()
    assert Pricing.cost_usd(:claude, model, @buckets) == ClaudePricing.cost_usd(model, @buckets)
    assert Pricing.cost_usd(:gemini, nil, @stats) == GeminiPricing.cost_usd(@stats)
    assert Pricing.cost_usd(:codex, "x", %{}) == nil
  end

  test "configured implementation is used" do
    Application.put_env(:wardmast, :pricing, Flat)
    assert Pricing.cost_usd(:claude, "any", @buckets) == 42.0
  end

  test "raising implementation yields nil" do
    Application.put_env(:wardmast, :pricing, Boom)
    assert Pricing.cost_usd(:claude, "any", @buckets) == nil
  end
end
