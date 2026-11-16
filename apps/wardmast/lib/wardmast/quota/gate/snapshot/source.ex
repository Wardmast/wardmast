defmodule Wardmast.Quota.Gate.Snapshot.Source do
  @moduledoc """
  Behaviour for the `:quota_snapshot` seam (`Wardmast.Extension`): projects one
  provider's persisted quota row onto the provider-neutral
  `Wardmast.Quota.Gate.Snapshot`.

  A source is registered under the **quota struct's module name**, as the
  string `Atom.to_string(MyApp.FooQuota)` (the registry atom is then the struct
  module itself). `Wardmast.Quota.Gate.Snapshot.normalize/2` looks a row's
  `__struct__` up in the registry, so a package that adds a provider with its
  own quota table needs no change to core to have its rows gated, projected by
  `Headroom` / `History`, and staleness-checked.

      {:quota_snapshot, Atom.to_string(MyApp.FooQuota), MyApp.FooQuota.Source}

  The three in-tree sources register through `Wardmast.Extensions.Core` the same
  way.
  """

  alias Wardmast.Quota.Gate.Snapshot

  @doc """
  Project `quota` (a row of the struct this source is registered for) onto
  `Wardmast.Quota.Gate.Snapshot`, or return `nil` to fail open. `opts` is what
  the caller passed to `Snapshot.normalize/2` (today only `:model`).
  """
  @callback normalize(quota :: struct(), opts :: keyword()) :: Snapshot.t() | nil
end
