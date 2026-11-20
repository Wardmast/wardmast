defmodule Wardmast.Trackers.ConnectionTest do
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.Workspace
  alias Wardmast.Trackers.Connection

  @token "ghp_super_secret_value"

  defp workspace(type, config, secrets \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "conn-#{System.unique_integer([:positive])}",
        prefix: "cn",
        secrets: secrets,
        config: %{"tracker" => %{"type" => type, "config" => config}}
      })

    ws
  end

  defp stub(fun), do: Req.Test.stub(Wardmast.Trackers.GitHub.HTTP, fun)

  @gh %{"owner" => "acme", "repo" => "widgets", "credentials_ref" => "secret:gh"}

  test "success reports the authenticated identity and sends the saved secret" do
    ws = workspace("github", @gh, %{"gh" => @token})

    stub(fn conn ->
      assert ["Bearer " <> @token] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.request_path == "/user"
      Req.Test.json(conn, %{"login" => "octocat"})
    end)

    assert {:ok, %{identity: "octocat", type: "github"}} = Connection.test(ws)
  end

  test "the tracker's own error is reported, without the token" do
    ws = workspace("github", @gh, %{"gh" => @token})

    stub(fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    assert {:error, message} = Connection.test(ws)
    assert message =~ "Bad credentials"
    refute message =~ @token
  end

  test "a message that echoes the secret value is scrubbed" do
    ws = workspace("github", @gh, %{"gh" => @token})

    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"message" => "token #{@token} is invalid"})
    end)

    assert {:error, message} = Connection.test(ws)
    refute message =~ @token
  end

  test "a credentials_ref naming a secret that is not stored says so" do
    ws = workspace("github", @gh)
    stub(fn _conn -> flunk("no request expected") end)

    assert {:error, message} = Connection.test(ws)
    assert message =~ "gh"
    assert message =~ "not set"
  end

  test "overrides test unsaved form values over the saved config" do
    ws = workspace("github", %{"owner" => "acme", "repo" => "widgets"}, %{"other" => "tok2"})

    stub(fn conn ->
      assert ["Bearer tok2"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"login" => "me"})
    end)

    assert {:ok, %{identity: "me"}} =
             Connection.test(ws, %{"credentials_ref" => "secret:other"})
  end

  test "a blank override unsets the saved value" do
    ws = workspace("github", @gh, %{"gh" => @token})
    stub(fn _conn -> flunk("no request expected") end)

    assert {:error, message} = Connection.test(ws, %{"credentials_ref" => ""})
    assert message =~ "credentials_ref"
  end

  test "no tracker configured is reported rather than silently passing" do
    ws = workspace("none", %{})
    assert {:error, message} = Connection.test(ws)
    assert message =~ "No tracker"
  end

  test "an override type selects that tracker's adapter" do
    ws = workspace("none", %{}, %{"gh" => "tok3"})
    stub(fn conn -> Req.Test.json(conn, %{"login" => "octo"}) end)

    assert {:ok, %{type: "github", identity: "octo"}} =
             Connection.test(ws, %{
               "type" => "github",
               "owner" => "a",
               "repo" => "b",
               "credentials_ref" => "secret:gh"
             })
  end
end
