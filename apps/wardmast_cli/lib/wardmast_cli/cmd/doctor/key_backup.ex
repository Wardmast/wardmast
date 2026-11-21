defmodule WardmastCli.Cmd.Doctor.KeyBackup do
  @moduledoc """
  `arb server doctor`'s "key backup" check: has the operator recorded a backup of
  the Cloak key?

  Losing the Cloak key makes every stored secret unreadable, so an install with no
  backup on record is a `warn`. The record is `<data-home>/cloak-key-backup.json`,
  written by the server (`Wardmast.KeyBackup`) when the key is exported from the
  dashboard's key backup page or acknowledged as backed up elsewhere. It holds a
  fingerprint, never the key, and this check only reads it.

  The data home is `WARDMAST_DATA_HOME` (what the desktop shell sets for the
  release), else the deploy data home (`ARB_DATA_HOME`, `~/.wardmast`).

  Tests (and `CliCase`, through `Process.get(:bd9_key_backup_probe)`) point it at
  a directory with `{:home, dir}` or switch it off with `:absent`.
  """

  alias WardmastCli.Cmd.Doctor.Checks.Result
  alias WardmastCli.Cmd.ReleaseDeploy.ReleaseFiles

  @name "key backup"
  @file_name "cloak-key-backup.json"

  @spec check() :: Result.t()
  def check, do: check(Process.get(:bd9_key_backup_probe, :live))

  @spec check(:live | :absent | {:home, Path.t()}) :: Result.t()
  def check(:absent), do: na("not checked")
  def check(:live), do: check({:home, data_home()})

  def check({:home, home}) do
    if File.dir?(home), do: report(home), else: na("no data home (#{home}) on this host")
  end

  defp report(home) do
    case read(Path.join(home, @file_name)) do
      {:ok, %{"recorded_at" => at, "method" => method, "fingerprint" => fp}} ->
        %Result{
          name: @name,
          status: :ok,
          detail: "Cloak key backup recorded #{at} (#{method}; key fingerprint #{fp})"
        }

      _ ->
        %Result{
          name: @name,
          status: :warn,
          detail:
            "no backup of the Cloak key is recorded: if the key is lost every stored secret " <>
              "becomes unreadable and cannot be recovered",
          hint:
            "Open the dashboard at /settings/key-backup (About → Back up the key) and export " <>
              "the key once, or record a backup you keep elsewhere. See " <>
              "#{WardmastCli.Version.doc_url("docs/secrets-at-rest.md")}."
        }
    end
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = record} <- Jason.decode(body) do
      {:ok, record}
    end
  end

  defp data_home do
    case Wardmast.Env.get("WARDMAST_DATA_HOME") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> ReleaseFiles.data_home()
    end
  end

  defp na(detail), do: %Result{name: @name, status: :na, detail: detail}
end
