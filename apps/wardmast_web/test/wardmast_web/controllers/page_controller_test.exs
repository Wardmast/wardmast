defmodule WardmastWeb.PageControllerTest do
  use WardmastWeb.ConnCase

  test "GET /about (PageController moved here when DashboardLive took /)", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "Wardmast"
  end

  test "GET /about displays Wardmast version and git SHA", %{conn: conn} do
    conn = get(conn, ~p"/about")
    html = html_response(conn, 200)

    assert html =~ Wardmast.Version.app_version()
    assert html =~ Wardmast.Version.git_sha()
  end
end
