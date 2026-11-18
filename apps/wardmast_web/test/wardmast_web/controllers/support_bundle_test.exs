defmodule WardmastWeb.SupportBundleTest do
  @moduledoc "Diagnostics bundle: dashboard download button and `GET /api/support/bundle` (operator)."
  use WardmastWeb.ConnCase, async: false

  alias Wardmast.MCP.Scope

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
  end

  test "a dashboard session downloads the tar.gz" do
    conn = get(dashboard_login(build_conn()), "/support/bundle")

    assert response(conn, 200)
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "gzip"
    assert [cd] = get_resp_header(conn, "content-disposition")
    assert cd =~ "arb-support-bundle-"
    {:ok, files} = :erl_tar.extract({:binary, conn.resp_body}, [:memory, :compressed])
    assert Enum.any?(files, fn {n, _} -> to_string(n) == "version.txt" end)
  end

  test "an anonymous browser is not served the bundle" do
    conn = get(build_conn(), "/support/bundle")
    assert conn.status in [302, 401, 403]
  end

  test "the About page carries the download button" do
    conn = get(dashboard_login(build_conn()), "/about")
    assert html_response(conn, 200) =~ "support-bundle-button"
  end

  test "operator gets base64 bundle over the API" do
    body =
      json_response(
        get(as(Scope.mint_coordinator(nil, operator: true)), "/api/support/bundle"),
        200
      )

    assert body["filename"] =~ "arb-support-bundle-"

    {:ok, files} =
      :erl_tar.extract({:binary, Base.decode64!(body["data_base64"])}, [:memory, :compressed])

    assert Enum.any?(files, fn {n, _} -> to_string(n) == "config.txt" end)
  end

  test "a non-operator coordinator session is refused" do
    conn = get(as(Scope.mint_coordinator(nil)), "/api/support/bundle")
    assert conn.status in [401, 403]
  end
end
