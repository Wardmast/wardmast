defmodule Wardmast.Mergers.GitlabHostImagesTest do
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.Gitlab
  alias Wardmast.Mergers.Gitlab.Config

  @ref "!42"
  @env_var "GTE_GITLAB_HOST_IMAGES_TOKEN"
  @project "/api/v4/projects/12345"

  @images [
    %{name: "edit__before.png", data: "PNG-BEFORE"},
    %{name: "edit__after.png", data: "PNG-AFTER"}
  ]

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main"
    })

    Wardmast.Mergers.Gitlab.Budget.reset()

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Wardmast.Mergers.Gitlab.HTTP, fun)
  defp json(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp visibility_stub(visibility, upload) do
    test = self()

    stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @project} ->
          json(conn, 200, %{"visibility" => visibility})

        {"POST", @project <> "/uploads"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:upload, Plug.Conn.get_req_header(conn, "private-token"), conn, body})
          upload.(conn, body)
      end
    end)
  end

  test "uploads each image through the project uploads API and returns its URL" do
    visibility_stub("private", fn conn, body ->
      name = if body =~ "PNG-BEFORE", do: "before", else: "after"

      json(conn, 201, %{
        "alt" => name,
        "url" => "/uploads/s3cret/#{name}.png",
        "full_path" => "/grp/proj/uploads/s3cret/#{name}.png",
        "markdown" => "![#{name}](/uploads/s3cret/#{name}.png)"
      })
    end)

    assert {:ok, results} = Gitlab.host_images(@ref, @images, %{})

    assert results == %{
             "edit__before.png" => {:ok, "/uploads/s3cret/before.png"},
             "edit__after.png" => {:ok, "/uploads/s3cret/after.png"}
           }

    assert_received {:upload, ["test-gitlab-token"], conn, body}
    assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    assert content_type =~ "multipart/form-data"
    assert body =~ ~s(filename="edit__before.png")
    assert body =~ "image/png"
  end

  test "a failed upload is reported per image with a reason, not skipped" do
    visibility_stub("private", fn conn, body ->
      if body =~ "PNG-BEFORE" do
        json(conn, 413, %{"message" => "File is too big"})
      else
        json(conn, 201, %{"url" => "/uploads/x/after.png"})
      end
    end)

    assert {:ok, results} = Gitlab.host_images(@ref, @images, %{})
    assert {:error, reason} = results["edit__before.png"]
    assert inspect(reason) =~ "too big"
    assert results["edit__after.png"] == {:ok, "/uploads/x/after.png"}
  end

  test "a public project is blocked unless public_repo_ok is set" do
    visibility_stub("public", fn conn, _ -> json(conn, 201, %{"url" => "/uploads/x/a.png"}) end)

    assert {:error, :public_repo_blocked} = Gitlab.host_images(@ref, @images, %{})
    refute_received {:upload, _, _, _}

    assert {:ok, %{"edit__after.png" => {:ok, _}}} =
             Gitlab.host_images(@ref, @images, %{public_repo_ok: true})
  end

  test "an unreadable visibility fails closed" do
    stub(fn conn -> json(conn, 403, %{"message" => "403 Forbidden"}) end)
    assert {:error, :public_repo_blocked} = Gitlab.host_images(@ref, @images, %{})
  end

  test "an internal project is treated like private" do
    visibility_stub("internal", fn conn, _ -> json(conn, 201, %{"url" => "/uploads/x/a.png"}) end)
    assert {:ok, _} = Gitlab.host_images(@ref, @images, %{})
  end

  test "get_description/1 reads just the MR description" do
    stub(fn conn ->
      assert conn.request_path == @project <> "/merge_requests/42"
      json(conn, 200, %{"description" => "the body"})
    end)

    assert {:ok, "the body"} = Gitlab.get_description(@ref)
  end

  test "get_description/1 is nil for an empty description and an error when unreadable" do
    stub(fn conn -> json(conn, 200, %{"description" => nil}) end)
    assert {:ok, nil} = Gitlab.get_description(@ref)

    stub(fn conn -> json(conn, 404, %{"message" => "404 Not found"}) end)
    assert {:error, _} = Gitlab.get_description(@ref)
  end
end
