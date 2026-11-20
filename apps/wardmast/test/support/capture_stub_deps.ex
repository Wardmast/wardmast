defmodule Wardmast.Test.CaptureStubDeps do
  @moduledoc """
  A stand-in for `Wardmast.Screenshots.Capture.DepsCache` (bd-3glf2a): `prepare/2` tells
  `opts[:test_pid]` what it was asked and answers `opts[:answer]` (default `{:ok, nil}`, no
  lockfile); `{:exit, reason}` exits instead.
  """

  @doc false
  def prepare(input, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:deps_prepare, input})

    case Keyword.get(opts, :answer, {:ok, nil}) do
      {:exit, reason} -> exit(reason)
      answer -> answer
    end
  end
end
