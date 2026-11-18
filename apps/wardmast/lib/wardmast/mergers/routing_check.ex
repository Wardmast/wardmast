defmodule Wardmast.Mergers.RoutingCheck do
  @moduledoc """
  Does each repo's effective merge strategy fit its checkout? (bd-73zv62)

  `arb server doctor` (via `GET /api/server/merge_routing`) lists, for every
  workspace and every `repo_paths` key, the repo's effective strategy
  (`Wardmast.Mergers.strategy/2`, honouring `merge.repos.<repo>`) and flags:

    * `:no_remote` — the strategy is a forge (`github` / `gitlab`) but the
      checkout has no parseable `origin` remote. A PR can never be opened for
      it: the worker pushes its branch to `origin` first. This is the
      remote-less infra repo inheriting the workspace's `github` strategy.
    * `:remote_mismatch` — the strategy is `github` and the effective
      `merge.config.owner` / `.repo` (or, for `gitlab`, a path-form `project_id`) are pinned to a different repository than
      the checkout's `origin` (compared case-insensitively). Its PRs would be
      opened against the wrong repository.

  A `direct` repo is never flagged. A repo whose checkout is missing on this
  host is reported without a problem: there is nothing on disk to compare.
  """

  alias Wardmast.Mergers
  alias Wardmast.Mergers.Github.RepoResolver
  alias Wardmast.Tasks.RepoConfig
  alias Wardmast.Tasks.Workspace

  @type problem :: :no_remote | :remote_mismatch | nil
  @type entry :: %{
          workspace_id: String.t() | nil,
          workspace: String.t() | nil,
          repo: String.t(),
          strategy: String.t(),
          remote: String.t() | nil,
          expected: String.t() | nil,
          problem: problem(),
          fix: String.t() | nil
        }

  @doc "Every workspace's entries. A failed workspace read is an empty list."
  @spec report() :: [entry()]
  def report do
    case Ash.read(Workspace) do
      {:ok, workspaces} -> Enum.flat_map(workspaces, &check_workspace/1)
      _ -> []
    end
  end

  @doc "One entry per `repo_paths` key of `workspace`, sorted by repo."
  @spec check_workspace(Workspace.t()) :: [entry()]
  def check_workspace(%Workspace{config: config} = workspace) do
    case config do
      %{"repo_paths" => paths} when is_map(paths) ->
        paths
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.map(fn {key, raw} ->
          check_repo(workspace, key, RepoConfig.repo_path_from_config(raw))
        end)

      _ ->
        []
    end
  end

  defp check_repo(workspace, key, path) do
    strategy = Mergers.strategy(workspace, key)
    merge = Mergers.merge_config(workspace, key)
    remote = remote_slug(strategy, path)
    expected = pinned_slug(strategy, merge)

    problem =
      cond do
        not Mergers.forge?(strategy) -> nil
        not checkout?(path) -> nil
        is_nil(remote) -> :no_remote
        expected && String.downcase(expected) != String.downcase(remote) -> :remote_mismatch
        true -> nil
      end

    %{
      workspace_id: workspace.id,
      workspace: workspace.name,
      repo: key,
      strategy: Atom.to_string(strategy),
      remote: remote,
      expected: expected,
      problem: problem,
      fix: fix(problem, workspace, key, strategy, remote)
    }
  end

  defp checkout?(path), do: is_binary(path) and File.dir?(path)

  # GitLab project paths nest (`group/sub/project`), which the two-segment
  # GitHub resolver cannot parse.
  defp remote_slug(:gitlab, path) do
    with true <- checkout?(path),
         {out, 0} <-
           System.cmd("git", ["-C", path, "remote", "get-url", "origin"], stderr_to_stdout: true),
         {:ok, project} <- Wardmast.Mergers.Gitlab.parse_remote_project(String.trim(out)) do
      project
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp remote_slug(_strategy, path) do
    if checkout?(path) do
      case RepoResolver.from_remote(path) do
        {:ok, {owner, name}} -> "#{owner}/#{name}"
        _ -> nil
      end
    end
  end

  defp pinned_slug(:github, %{"config" => %{"owner" => owner, "repo" => repo}})
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "",
       do: "#{owner}/#{repo}"

  # A GitLab `project_id` is only comparable when it is the URL-encoded path
  # form (`group/project` / `group%2Fproject`); a numeric id says nothing about
  # the remote's path, so it is never flagged.
  defp pinned_slug(:gitlab, %{"config" => %{"project_id" => id}}) when is_binary(id) do
    path = URI.decode(id)
    if String.contains?(path, "/"), do: path, else: nil
  end

  defp pinned_slug(_strategy, _merge), do: nil

  defp fix(nil, _ws, _key, _strategy, _remote), do: nil

  defp fix(:no_remote, ws, key, strategy, _remote) do
    "`arb config set merge.repos.#{key}.strategy direct#{workspace_flag(ws)}` to merge it " <>
      "locally, or add an `origin` remote for the #{strategy} repository it belongs to"
  end

  defp fix(:remote_mismatch, ws, key, :gitlab, remote) do
    "`arb config set merge.repos.#{key}.config.project_id #{remote}#{workspace_flag(ws)}` to open its " <>
      "MRs against its own project, or `merge.repos.#{key}.strategy direct` to merge it locally"
  end

  defp fix(:remote_mismatch, ws, key, _strategy, remote) do
    [owner, name] = String.split(remote, "/", parts: 2)

    "`arb config set merge.repos.#{key}.config.owner #{owner}#{workspace_flag(ws)}` and " <>
      "`arb config set merge.repos.#{key}.config.repo #{name}#{workspace_flag(ws)}` to open its " <>
      "PRs against its own repository, or `merge.repos.#{key}.strategy direct` to merge it locally"
  end

  defp workspace_flag(%Workspace{name: name}) when is_binary(name) and name != "",
    do: " --workspace #{name}"

  defp workspace_flag(_ws), do: ""
end
