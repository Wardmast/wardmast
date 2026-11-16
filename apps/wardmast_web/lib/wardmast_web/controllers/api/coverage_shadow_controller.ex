defmodule WardmastWeb.Api.CoverageShadowController do
  @moduledoc """
  `GET /api/coverage_shadow/preflip_gate` — the operator surface for
  `Wardmast.Reviews.CoverageShadow.preflip_gate/0`. Backs `arb preflip-gate`.

  bd-cy2mmu: before this route existed, the function that decides whether the
  review-coverage shadow data justifies flipping `merge.coverage_enabled` had
  no caller outside its own tests — an operator could only run it by hand
  against `iex -S mix` on the install's own database. This is a thin,
  read-only wrapper: no arguments, no side effects, the gate's own map
  encoded straight to JSON.
  """

  use WardmastWeb, :controller

  alias Wardmast.Reviews.CoverageShadow

  def preflip_gate(conn, _params) do
    render(conn, :preflip_gate, gate: CoverageShadow.preflip_gate())
  end
end
