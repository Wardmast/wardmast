defmodule Mix.Tasks.Wardmast.BackfillCodexUsage do
  @shortdoc "Recover zero-token codex usage_events rows from on-disk rollout JSONL"
  @moduledoc """
  Backfill `usage_events` rows for codex probes whose live capture landed
  with `tokens_in`/`tokens_out: nil` before bd-96mn8i taught
  `Wardmast.Usage.Probe` codex's `turn.completed` wire shape (bd-96mn8i round
  2, finding 1).

  ## Usage

      mix wardmast.backfill_codex_usage                    # dry-run (default)
      mix wardmast.backfill_codex_usage --apply             # write the rows
      mix wardmast.backfill_codex_usage --since 2026-09-14  # rows occurring on/after
      mix wardmast.backfill_codex_usage --until 2026-09-21  # rows occurring before
      mix wardmast.backfill_codex_usage --limit 200 --apply # chip away in batches

  Dry-run is the default and prints exactly what a `--apply` pass would
  write. The pass only ever touches rows matching `provider == "codex" and
  is_nil(tokens_in)`, so re-running converges rather than re-writing rows a
  previous pass already recovered.

  See `Wardmast.Usage.CodexUsageBackfill` for the matching/recovery logic and
  `Wardmast.Usage.CodexSessionFile` for the on-disk rollout format.

  ## Release installs

  This is a thin CLI wrapper over `Wardmast.Release.backfill/2`, which is
  Mix-free and callable from a release install with no Elixir toolchain:

      bin/wardmast eval 'Wardmast.Release.backfill(:codex_usage)'             # dry-run
      bin/wardmast eval 'Wardmast.Release.backfill(:codex_usage, apply?: true)'

  It starts only Ash + the Ecto repo, never the full app-boot task ("app.start"):
  booting the full application next to a live coordinator would start a
  second endpoint on the same port, a second Autopilot and a second set of
  patrols against the same database.
  """

  use Mix.Task

  @switches [
    apply: :boolean,
    since: :string,
    until: :string,
    limit: :integer,
    tolerance_ms: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    backfill_opts =
      [apply?: opts[:apply] == true]
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:tolerance_ms, opts[:tolerance_ms])
      |> put_opt(:since, date(opts[:since], "--since"))
      |> put_opt(:until, date(opts[:until], "--until"))

    Wardmast.Release.backfill(:codex_usage, Keyword.put(backfill_opts, :hint, "--apply"))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp date(nil, _flag), do: nil

  defp date(value, flag) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _} -> Mix.raise("#{flag} must be an ISO8601 date or datetime, got: #{value}")
        end
    end
  end
end
