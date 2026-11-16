defmodule Wardmast.ReviewGate do
  @moduledoc """
  Ash domain for durable, structured `Wardmast.Worker.ReviewGate` round outcomes
  (bd-aqyjuc), and the coordinator's recorded answer when a gate escalates
  (bd-4qjl0q).

  See `Wardmast.ReviewGate.Round` and `Wardmast.ReviewGate.Resolution` for the
  schemas and rationale.
  """

  use Ash.Domain

  resources do
    resource Wardmast.ReviewGate.Round
    resource Wardmast.ReviewGate.Resolution
  end
end
