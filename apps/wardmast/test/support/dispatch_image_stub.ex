defmodule Wardmast.DispatchImageStub do
  @moduledoc """
  SI13: every node takes the published image, so a dispatch placed on a (fake) node
  publishes first. Tests that only care about placement hand `publish/0` to the dispatch
  so the publish is a stub that returns a pinned ref.
  """

  @ref "registry.example.com/arbiter/worker@sha256:" <> String.duplicate("b", 64)

  @doc "`publish:` options whose stub reports an already-published image."
  @spec publish() :: keyword()
  def publish, do: [stub: fn _ctx -> {:ok, %{ref: @ref}} end]

  @doc "`plan:` options that resolve the base image without a registry or podman."
  @spec plan() :: keyword()
  def plan,
    do: [resolver: fn _ref -> {:ok, "sha256:" <> String.duplicate("c", 64)} end, arb_otp: "27.0"]
end
