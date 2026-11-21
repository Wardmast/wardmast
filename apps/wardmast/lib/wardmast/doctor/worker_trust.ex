defmodule Wardmast.Doctor.WorkerTrust do
  @moduledoc """
  Which configured repo paths the worker Claude profile has not trusted
  (bd-3ipnbp, GitHub #1299).

  Claude ignores a workspace's `.claude/settings.json` `permissions.allow`
  entries ("this workspace has not been trusted") unless the profile's
  `.claude.json` has `projects.<path>.hasTrustDialogAccepted == true`. The
  isolated worker profile (`Wardmast.Agents.Claude.ConfigDir`) is created once,
  so a repo first used afterwards is never trusted. `arb server doctor` lists
  those repos via `GET /api/server/worker_trust`.
  """

  alias Wardmast.Agents.Claude.ConfigDir

  @type report :: %{
          config_dir: String.t(),
          profile_present: boolean(),
          checked: non_neg_integer(),
          untrusted: [String.t()]
        }

  @doc "Report for every repo path with a configured path, against the live worker profile."
  @spec report() :: report()
  def report do
    paths = for %{path: p} <- Wardmast.Repos.list(), is_binary(p), do: p
    report(paths, ConfigDir.path())
  end

  @spec report([String.t()], String.t()) :: report()
  def report(paths, config_dir) do
    paths = paths |> Enum.uniq() |> Enum.sort()
    file = Path.join(config_dir, ".claude.json")

    {present?, projects} =
      case File.read(file) do
        {:ok, raw} -> {true, decode_projects(raw)}
        {:error, _} -> {false, %{}}
      end

    %{
      config_dir: config_dir,
      profile_present: present?,
      checked: length(paths),
      untrusted: Enum.reject(paths, &trusted?(projects, &1))
    }
  end

  defp decode_projects(raw) do
    case Jason.decode(raw) do
      {:ok, %{"projects" => %{} = projects}} -> projects
      _ -> %{}
    end
  end

  defp trusted?(projects, path) do
    match?(%{"hasTrustDialogAccepted" => true}, Map.get(projects, path))
  end
end
