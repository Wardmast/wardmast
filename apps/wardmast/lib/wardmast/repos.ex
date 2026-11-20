defmodule Wardmast.Repos do
  @moduledoc """
  Core context for repos — named repository checkouts that workers operate on.

  A repo is discovered from three sources:
    * each workspace's `config["repo_paths"]` map,
    * the application-env fallback `:wardmast, :repo_paths` (`source: "(app)"`),
    * any repo name a live worker is running against that isn't configured
      anywhere, or that an open ticket carries (bd-7u1b6n) — `source:
      "(unconfigured)"`.

  Repo listing is workspace-aware and does not collapse same-named repos
  across workspaces (parity audit P-24, D-C-31).

  Note on worker counts: active worker processes in Wardmast register with
  their repo name. When the same repo name is configured in multiple workspaces,
  active workers running against that repo name are counted globally for that repo
  name across workspaces.
  """

  require Ash.Query

  alias Wardmast.Tasks.RepoConfig
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker
  alias Wardmast.Worker.PrimarySync
  alias Wardmast.Worker.Worktree

  @type repo :: %{
          name: String.t(),
          path: String.t() | nil,
          source: String.t(),
          workers: non_neg_integer(),
          worktrees: non_neg_integer(),
          workspace_id: String.t() | nil,
          primary_target: String.t(),
          primary_behind: non_neg_integer() | nil,
          primary_sync_blocker: PrimarySync.skip_reason() | nil,
          auto_sync_primary: boolean()
        }

  @doc """
  List registered repos with their path, source, active worker count, and git worktree count.

  Options:
    * `:workspace_id` — filter to repos configured in this workspace
    * `:workspace` — filter to repos in this `%Workspace{}` struct
  """
  @spec list(keyword()) :: [repo()]
  def list(opts \\ []) do
    workspaces = load_workspaces(opts)
    workers_by_repo = group_workers_by_repo()

    ws_entries = collect_workspace_repos(workspaces)
    ws_names = MapSet.new(ws_entries, & &1.name)

    # App-env fallback applies globally when not scoped to a specific workspace
    scoped? = Keyword.has_key?(opts, :workspace_id) or Keyword.has_key?(opts, :workspace)

    app_entries =
      if scoped? do
        []
      else
        collect_app_repos(ws_names)
      end

    configured_names =
      ws_names
      |> MapSet.union(MapSet.new(app_entries, & &1.name))

    worker_entries =
      if scoped? do
        []
      else
        repos_from_workers(workers_by_repo, configured_names) ++
          repos_from_open_tickets(configured_names, workers_by_repo)
      end

    (ws_entries ++ app_entries ++ worker_entries)
    |> Enum.map(fn entry ->
      path = entry.path

      worktree_count =
        case path do
          nil -> 0
          p when is_binary(p) -> safe_worktree_count(p)
        end

      target = Map.get(entry, :target) || "main"

      %{
        name: entry.name,
        path: path,
        source: entry.source,
        workspace_id: entry.workspace_id,
        workers: Map.get(workers_by_repo, entry.name, 0),
        worktrees: worktree_count,
        primary_target: target,
        auto_sync_primary: Map.get(entry, :auto_sync_primary, false)
      }
      |> Map.merge(primary_staleness(path, target))
    end)
    |> Enum.sort_by(&{&1.name, &1.source})
  end

  @doc """
  Find all repos matching `name`. Accepts the same options as `list/1`.
  """
  @spec get_all(String.t(), keyword()) :: [repo()]
  def get_all(name, opts \\ []) when is_binary(name) do
    list(opts)
    |> Enum.filter(fn repo -> repo.name == name end)
  end

  @doc """
  Find a single repo by name.

  Returns `{:ok, repo}`, `{:error, {:not_found, msg}}`, or
  `{:error, {:invalid_request, msg, details}}` if multiple workspaces define
  a repo with the same name and no workspace qualifier was passed.
  Accepts the same options as `list/1`.
  """
  @spec get(String.t(), keyword()) ::
          {:ok, repo()}
          | {:error, {:not_found, String.t()}}
          | {:error, {:invalid_request, String.t(), map()}}
  def get(name, opts \\ []) when is_binary(name) do
    case get_all(name, opts) do
      [] ->
        {:error, {:not_found, "repo #{inspect(name)} not found"}}

      [repo] ->
        {:ok, repo}

      matches ->
        sources = Enum.map_join(matches, ", ", & &1.source)

        {:error,
         {:invalid_request,
          "repo #{inspect(name)} is ambiguous; found in workspaces: #{sources}. Specify workspace to disambiguate",
          %{workspaces: Enum.map(matches, &%{source: &1.source, workspace_id: &1.workspace_id})}}}
    end
  end

  # ---- internal helpers ----

  defp load_workspaces(opts) do
    cond do
      ws = Keyword.get(opts, :workspace) ->
        case ws do
          %Workspace{} -> [ws]
          _ -> []
        end

      ws_id = Keyword.get(opts, :workspace_id) ->
        Workspace
        |> Ash.Query.filter(id == ^ws_id or name == ^ws_id)
        |> Ash.read!()

      true ->
        Ash.read!(Workspace)
    end
  rescue
    _ -> []
  end

  defp collect_workspace_repos(workspaces) do
    Enum.flat_map(workspaces, fn ws ->
      ws_repo_paths =
        case ws.config do
          %{"repo_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.map(ws_repo_paths, fn {name, raw} ->
        %{
          name: name,
          path: RepoConfig.repo_path_from_config(raw),
          target: RepoConfig.repo_target_from_config(raw),
          source: ws.name,
          workspace_id: ws.id,
          auto_sync_primary: Workspace.auto_sync_primary?(ws)
        }
      end)
    end)
  end

  defp collect_app_repos(ws_names) do
    :wardmast
    |> Application.get_env(:repo_paths, %{})
    |> Enum.reject(fn {name, _raw} -> MapSet.member?(ws_names, name) end)
    |> Enum.map(fn {name, raw} ->
      %{
        name: name,
        path: RepoConfig.repo_path_from_config(raw),
        target: RepoConfig.repo_target_from_config(raw),
        source: "(app)",
        workspace_id: nil
      }
    end)
  end

  defp repos_from_workers(workers_by_repo, configured_names) do
    workers_by_repo
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(configured_names, &1))
    |> Enum.map(fn name ->
      %{
        name: name,
        path: nil,
        source: "(unconfigured)",
        workspace_id: nil
      }
    end)
  end

  # bd-7u1b6n: open tickets whose `repo` is not a configured key. They dispatch
  # (or fail to resume) against a repo nothing can resolve; surfacing them here
  # puts them in `arb repo list` and in `arb server doctor`.
  defp repos_from_open_tickets(configured_names, workers_by_repo) do
    Wardmast.Tasks.Issue
    |> Ash.Query.filter(state != :closed and not is_nil(repo))
    |> Ash.Query.select([:repo])
    |> Ash.read!()
    |> Enum.map(& &1.repo)
    |> Enum.uniq()
    |> Enum.reject(&(MapSet.member?(configured_names, &1) or Map.has_key?(workers_by_repo, &1)))
    |> Enum.map(fn name ->
      %{name: name, path: nil, source: "(unconfigured)", workspace_id: nil}
    end)
  rescue
    _ -> []
  end

  defp group_workers_by_repo do
    try do
      Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      repo = p.repo || "(none)"
      Map.update(acc, repo, 1, &(&1 + 1))
    end)
  end

  # bd-2rdfsh: how far the checkout's LOCAL target branch trails origin, and why
  # a post-merge sync would not catch it up. `nil` = unknown (no path, not a git
  # checkout, no such branch): doctor must not warn on what it cannot measure.
  defp primary_staleness(path, target) when is_binary(path) do
    case PrimarySync.status(path, target) do
      {:ok, %{behind: behind, blocker: blocker}} ->
        %{primary_behind: behind, primary_sync_blocker: blocker}

      {:error, _} ->
        %{primary_behind: nil, primary_sync_blocker: nil}
    end
  rescue
    _ -> %{primary_behind: nil, primary_sync_blocker: nil}
  end

  defp primary_staleness(_path, _target), do: %{primary_behind: nil, primary_sync_blocker: nil}

  defp safe_worktree_count(path) do
    Worktree.list(path) |> length()
  rescue
    _ -> 0
  end
end
