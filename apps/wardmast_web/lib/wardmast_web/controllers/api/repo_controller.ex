defmodule WardmastWeb.Api.RepoController do
  @moduledoc """
  REST endpoint for repos — the repo/project keys workers operate on.

  Routes:

    * `GET /api/repos` — :index
    * `GET /api/repos/:name` — :show

  A "repo" is a named repository checkout. Repos are discovered from three
  sources:

    * each workspace's `config["repo_paths"]` map,
    * the application-env `:wardmast, :repo_paths` fallback (`source: "(app)"`),
    * any repo name a live worker is running against that isn't configured
      anywhere (`source: "(unconfigured)"`).

  For each repo the response carries the number of active workers and the
  number of git worktrees resident at its path.
  """

  use WardmastWeb, :controller

  alias Wardmast.Repos
  alias WardmastWeb.Api.WorkspaceParam

  action_fallback(WardmastWeb.Api.FallbackController)

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      opts = if ws_id, do: [workspace_id: ws_id], else: []
      render(conn, :index, repos: Repos.list(opts))
    end
  end

  def show(conn, %{"name" => name} = params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         opts = if(ws_id, do: [workspace_id: ws_id], else: []),
         {:ok, repo} <- Repos.get(name, opts) do
      render(conn, :show, repo: repo)
    end
  end
end
