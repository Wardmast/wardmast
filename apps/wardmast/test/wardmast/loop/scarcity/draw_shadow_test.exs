defmodule Wardmast.Loop.Scarcity.DrawShadowTest do
  @moduledoc """
  R3 is shadow output only (bd-3is1nz, design §9): the calibration reads the
  history and prints; it never writes, and no routing or gate path consumes it.
  The §9 no-regression invariant therefore holds by construction, and these
  tests pin the construction.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Quota.QuotaSnapshot
  alias Wardmast.Usage

  @lib Path.expand("../../../../lib", __DIR__)
  @consumers ~r/Scarcity\.Draw|Scarcity\.Calibration|draw_share|draw_calibration/

  # The only files allowed to name the calibration: its own modules, the
  # `Scarcity` seam, and the two operator entry points. DC2's seat-hour
  # calibration (bd-c1dief) reuses `Calibration.fit/2` and `Draw.intervals/3`
  # and is itself pinned shadow-only by `Quota.BudgetCalibrationShadowTest`.
  # `quota/seat_weights.ex` (DC11, bd-8lsfey, R11 folded in) is the one consumer of
  # the per-model fit: it turns it into seat weights the budget server holds, and
  # only `SeatCheck` (enforce) and the walk read those (`SeatWeightsTest` pins it).
  @allowed ~w(
    wardmast/loop/scarcity.ex
    wardmast/loop/scarcity/draw.ex
    wardmast/loop/scarcity/calibration.ex
    wardmast/release.ex
    wardmast/quota/budget_calibration.ex
    wardmast/quota/seat_weights.ex
    mix/tasks/wardmast.draw_calibration.ex
    mix/tasks/wardmast.budget_calibration.ex
    wardmast/quota/history.ex
  )

  test "no routing, gate, dispatch or board module consumes the calibration" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.relative_to(&1, @lib) in @allowed))
      |> Enum.filter(&(File.read!(&1) =~ @consumers))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end

  test "calibrating writes nothing" do
    account = Ecto.UUID.generate()
    t0 = ~U[2026-10-01 00:00:00Z]

    for i <- 0..9 do
      Ash.create!(QuotaSnapshot, %{
        provider_account_id: account,
        provider: "claude",
        bucket: "claude",
        window: "5h",
        utilization: 0.01 * i,
        resets_at: DateTime.add(t0, 300 * 60, :second),
        captured_at: DateTime.add(t0, i * 1800, :second)
      })
    end

    snapshots = length(Ash.read!(QuotaSnapshot))
    events = length(Ash.read!(Usage.Event))

    results = Wardmast.Loop.Scarcity.Draw.calibrate(since: DateTime.add(t0, -1, :second))
    assert [%{fit: %{status: :insufficient_data}}] = results

    assert length(Ash.read!(QuotaSnapshot)) == snapshots
    assert length(Ash.read!(Usage.Event)) == events
  end

  test "an empty history is reported, not fabricated" do
    assert Wardmast.Loop.Scarcity.Draw.calibrate() == []

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Wardmast.Release.draw_calibration(start: false) == []
      end)

    assert output =~ "No quota history"
  end
end
