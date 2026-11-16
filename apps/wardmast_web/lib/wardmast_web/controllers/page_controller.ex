defmodule WardmastWeb.PageController do
  use WardmastWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      issues_label: "Tickets",
      workers_label: "Workers",
      domains_label: "Workspaces",
      app_version: Wardmast.Version.app_version(),
      git_sha: Wardmast.Version.git_sha()
    )
  end
end
