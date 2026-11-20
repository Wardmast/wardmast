defmodule Wardmast.Worker.ReviewGate.ScreenshotAlert do
  @moduledoc """
  The soft attention for a capture-infrastructure failure (bd-ur1zty; design
  `docs/design/ui-screenshot-capture.md` §2.3: "a failed capture never fails a merge: it raises a
  soft attention (`screenshot_capture_failed`)").

  A capture that fails for a reason that is neither the worker's nor the change's (the offline
  deps cache, a capture service, the checkout, the browser, the base's own boot: see
  `ScreenshotGate.classify/1`) no longer parks the ticket; the review runs without screenshots.
  The coordinator still has to know, and it is the same fault for every UI ticket of the repo until
  it is fixed, so it is one coordinator-owned `:screenshot_capture_failed` **system alert per
  workspace, repo and cause**, not one per ticket: a later ticket failing the same way refreshes
  it (`raise_count`, the latest ticket and message in its detail). A capture that works clears the
  repo's alerts.

  Best-effort: bookkeeping must never take a ReviewGate down.
  """

  alias Wardmast.Alerts
  alias Wardmast.Screenshots.Capture.Failure

  require Logger

  @kind :screenshot_capture_failed
  @causes ~w(deps_failed services_failed boot_failed checkout_failed diff_failed shot_failed
             budget_exceeded)

  @doc "The alert kind."
  @spec kind() :: :screenshot_capture_failed
  def kind, do: @kind

  @doc "The cause an infrastructure `failure` is filed under (one alert per repo and cause)."
  @spec cause(Failure.t()) :: String.t()
  def cause(%Failure{detail: %{phase: :services}}), do: "services_failed"
  def cause(%Failure{code: code}), do: Atom.to_string(code)

  @doc "Raise (or refresh) the alert for `failure` on `task_id` in `repo` of `workspace_id`."
  @spec raise_failure(map(), Failure.t()) :: :ok
  def raise_failure(%{task_id: task_id, repo: repo} = state, %Failure{} = failure) do
    cause = cause(failure)
    repo_label = repo || "(unknown repo)"

    result =
      Alerts.raise_alert(%{
        kind: @kind,
        key: key(state, cause),
        workspace_id: Map.get(state, :workspace_id),
        subject: "UI screenshot capture failing for #{repo_label} (#{cause})",
        detail:
          "UI screenshots could not be captured for #{repo_label} (ticket #{task_id}): " <>
            "#{failure.message}. The review went ahead without screenshots; this is not the " <>
            "worker's or the change's doing. Fix the repo's `screenshots` config or the capture " <>
            "host (docs/screenshots.md); the alert clears when a capture works.",
        owner: :coordinator
      })

    case result do
      {:ok, _alert} -> :ok
      {:error, reason} -> Logger.warning("ScreenshotAlert: could not raise: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.warning("ScreenshotAlert: could not raise: #{Exception.message(e)}")
      :ok
  end

  @doc "A capture worked for `state`'s repo: its alerts are over."
  @spec clear(map()) :: :ok
  def clear(state) do
    if open?(state) do
      Enum.each(@causes, &Alerts.clear(@kind, key(state, &1)))
    end

    :ok
  rescue
    e ->
      Logger.warning("ScreenshotAlert: could not clear: #{Exception.message(e)}")
      :ok
  end

  # One read on the common path (no alert open), not one per cause.
  defp open?(state) do
    prefix = key_prefix(state)

    [kind: @kind]
    |> Alerts.active()
    |> Enum.any?(&String.starts_with?(&1.key, prefix))
  end

  defp key(state, cause), do: key_prefix(state) <> cause

  defp key_prefix(state),
    do: "#{Map.get(state, :workspace_id)}/#{Map.get(state, :repo)}/"
end
