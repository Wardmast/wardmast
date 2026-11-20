defmodule Wardmast.Screenshots.Captures do
  @moduledoc """
  The durable screenshot capture lifecycle (bd-8qj1sa): one `Wardmast.Screenshots.CaptureRecord`
  row per capture attempt for a ticket (head, base, `plan_hash`, `config_hash`, state).

  The ReviewGate writes through this module around each capture (`begin_attempt/1`, `finish/2`),
  cancels a stale attempt when a newer head arrives (`supersede/2`), and reads `history/1` to
  enforce `limits.max_captures_per_ticket` and to find the last captured head for the re-capture
  skip. State survives a restart; before this the only record was `capture.json` on disk and the
  gate's in-memory `screenshot_checked`.
  """

  import Ecto.Query

  alias Wardmast.Repo
  alias Wardmast.Screenshots.Capture.Failure
  alias Wardmast.Screenshots.CaptureRecord
  alias Wardmast.Screenshots.Config

  # Failures that happen before anything is booted (the worker's plan is bad): not an attempt.
  @no_boot_codes ~w(manifest_missing manifest_invalid)

  # A capture's own outcome, or a skip the gate records itself (`{:skipped, {:unchanged | :cap, why}}`).
  @type outcome ::
          Wardmast.Screenshots.Capture.run_outcome() | {:skipped, {atom(), String.t()}}

  @type history :: %{attempts: non_neg_integer(), last_captured: CaptureRecord.t() | nil}

  @doc "Insert a `running` row. `attrs`: task_id, workspace_id, head_sha, base_sha, plan_hash, config_hash, out_dir."
  @spec begin_attempt(map()) :: {:ok, CaptureRecord.t()} | {:error, term()}
  def begin_attempt(attrs) do
    row = struct(CaptureRecord, Map.put(Map.take(attrs, fields()), :state, "running"))

    case Repo.insert(row) do
      {:ok, rec} -> {:ok, rec}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Record how `record`'s capture ended. A row already `superseded` stays superseded: the capture
  that was cancelled does not get to claim it finished.
  """
  @spec finish(CaptureRecord.t(), outcome()) :: {:ok, CaptureRecord.t()}
  def finish(%CaptureRecord{id: id}, outcome) do
    changes = outcome_changes(outcome) |> Map.put(:finished_at, DateTime.utc_now())

    {_, _} =
      Repo.update_all(
        from(c in CaptureRecord, where: c.id == ^id and c.state == "running"),
        set: Map.to_list(changes)
      )

    {:ok, Repo.get!(CaptureRecord, id)}
  end

  @doc """
  Mark every `running` attempt for `task_id` whose head is not `head_sha` as `superseded`.
  Returns how many rows changed.
  """
  @spec supersede(String.t(), String.t()) :: non_neg_integer()
  def supersede(task_id, head_sha) do
    {n, _} =
      Repo.update_all(
        from(c in CaptureRecord,
          where: c.task_id == ^task_id and c.state == "running" and c.head_sha != ^head_sha
        ),
        set: [
          state: "superseded",
          reason: "a newer head arrived (#{String.slice(head_sha, 0, 12)})",
          finished_at: DateTime.utc_now()
        ]
      )

    n
  end

  @doc "Every attempt for `task_id`, oldest first."
  @spec list(String.t()) :: [CaptureRecord.t()]
  def list(task_id) do
    Repo.all(
      from c in CaptureRecord,
        where: c.task_id == ^task_id,
        order_by: [asc: c.inserted_at, asc: c.id]
    )
  end

  @doc """
  What the gate needs to decide whether to capture again: `attempts` is the number of attempts
  that booted the app (everything but `skipped` and a bad-manifest failure), `last_captured` the newest `captured` row.
  """
  @spec history(String.t()) :: history()
  def history(task_id) do
    attempts =
      Repo.aggregate(
        from(c in CaptureRecord,
          where:
            c.task_id == ^task_id and c.state != "skipped" and
              (is_nil(c.failure_code) or c.failure_code not in ^@no_boot_codes)
        ),
        :count
      )

    last =
      Repo.one(
        from c in CaptureRecord,
          where: c.task_id == ^task_id and c.state == "captured",
          order_by: [desc: c.inserted_at, desc: c.id],
          limit: 1
      )

    %{attempts: attempts, last_captured: last}
  end

  @doc "A stable hash of the resolved `screenshots` config."
  @spec config_hash(Config.t()) :: String.t()
  def config_hash(%Config{} = config),
    do: config |> :erlang.term_to_binary([:deterministic]) |> sha()

  @doc "The sha256 of the plan file at `path`, or `nil` when there is none."
  @spec plan_hash(String.t() | nil) :: String.t() | nil
  def plan_hash(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> sha(body)
      {:error, _} -> nil
    end
  end

  def plan_hash(_path), do: nil

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp fields,
    do: [:task_id, :workspace_id, :head_sha, :base_sha, :plan_hash, :config_hash, :out_dir]

  defp outcome_changes({:ok, result}),
    do: %{state: "captured", pair_count: length(Map.get(result, :pairs, []))}

  defp outcome_changes({:skipped, {kind, reason}}),
    do: %{state: "skipped", reason: "#{kind}: #{reason}"}

  defp outcome_changes({:skipped, kind}), do: %{state: "skipped", reason: to_string(kind)}

  defp outcome_changes({:error, %Failure{code: code, message: message}}),
    do: %{state: "failed", failure_code: to_string(code), reason: message}
end
