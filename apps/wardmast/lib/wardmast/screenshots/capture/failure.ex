defmodule Wardmast.Screenshots.Capture.Failure do
  @moduledoc """
  Why a capture did not produce its before/after pairs. `code` is the stable, machine-readable
  reason (the ReviewGate and the PR section act on it); `message` is the human sentence.

  | code | meaning |
  |---|---|
  | `:manifest_missing` | the worker's `.arbiter/screenshots.json` is not there |
  | `:manifest_invalid` | it is there but does not validate (`detail` = the errors) |
  | `:diff_failed` | git could not say which files changed |
  | `:checkout_failed` | a commit's source tree could not be extracted |
  | `:boot_failed` | the app did not boot at `role` (`detail` = phase and output; for a capture service that did not come up, phase `:services` with the service, reason and its log tail) |
  | `:deps_failed` | the offline Mix deps cache (`deps.mix`) could not be built (bd-3glf2a) |
  | `:fixture_marker_mismatch` | the booted app did not pass `fixture_check.marker` (it may be running on real data); nothing was shot (bd-995svb) |
  | `:app_not_ready` | the booted app stopped answering before the side's first navigation (`server_log` has its output tail) |
  | `:route_error` | a route answered with an error status (or was missing at both commits) |
  | `:shot_failed` | the browser step failed (a selector, a timeout, a crash) |
  | `:budget_exceeded` | the pass ran out of its `budget_seconds` |
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :role, :shot, :detail, :server_log]

  @type code ::
          :manifest_missing
          | :manifest_invalid
          | :diff_failed
          | :checkout_failed
          | :boot_failed
          | :deps_failed
          | :app_not_ready
          | :fixture_marker_mismatch
          | :route_error
          | :shot_failed
          | :budget_exceeded

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          role: String.t() | nil,
          shot: String.t() | nil,
          detail: term(),
          server_log: String.t() | nil
        }

  @doc "Build a failure; `fields` are `:role`, `:shot`, `:detail`."
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, fields \\ []),
    do: struct!(__MODULE__, [code: code, message: message] ++ fields)

  @doc "A JSON-safe map of the failure."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = f) do
    %{
      "code" => Atom.to_string(f.code),
      "message" => String.replace_invalid(f.message),
      "role" => f.role,
      "shot" => f.shot,
      "detail" => json(f.detail),
      "server_log" => json(f.server_log)
    }
  end

  # An app's or a service's output need not be UTF-8 (and a tail can cut a character in two):
  # what goes into `capture.json` always is.
  defp json(nil), do: nil
  defp json(v) when is_binary(v), do: String.replace_invalid(v)

  defp json(v) when is_list(v),
    do: if(Enum.all?(v, &is_binary/1), do: Enum.map(v, &json/1), else: inspect(v))

  defp json(v), do: String.replace_invalid(inspect(v))
end
