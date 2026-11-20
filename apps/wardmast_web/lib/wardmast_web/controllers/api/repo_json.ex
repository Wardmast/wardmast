defmodule WardmastWeb.Api.RepoJSON do
  @moduledoc "Render functions for repo aggregates (see `RepoController`)."

  def index(%{repos: repos}) do
    %{data: Enum.map(repos, &data/1)}
  end

  def show(%{repo: repo}), do: data(repo)

  def data(repo) do
    %{
      name: repo.name,
      path: repo.path,
      source: repo.source,
      workspace_id: repo.workspace_id,
      workers: repo.workers,
      worktrees: repo.worktrees,
      primary_target: repo.primary_target,
      primary_behind: repo.primary_behind,
      primary_sync_blocker: repo.primary_sync_blocker && to_string(repo.primary_sync_blocker),
      auto_sync_primary: repo.auto_sync_primary
    }
  end
end
