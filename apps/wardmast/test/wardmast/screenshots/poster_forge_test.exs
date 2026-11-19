defmodule Wardmast.Screenshots.PosterForgeTest do
  @moduledoc """
  The Poster driven through the real GitLab and GitHub adapters against stubbed
  forge APIs: the table written to the description renders the hosted images
  inline, and a later round replaces it.
  """
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.{Github, Gitlab}
  alias Wardmast.Screenshots.{Poster, Section}

  @gl_env "GTE_POSTER_GITLAB_TOKEN"
  @gh_env "GTE_POSTER_GITHUB_TOKEN"

  defp pairs(tag) do
    [
      %{
        label: "Edit modal",
        before: %{name: "edit.png", data: "BEFORE-#{tag}"},
        after: %{name: "edit.png", data: "AFTER-#{tag}"}
      }
    ]
  end

  defp markers(body), do: length(String.split(body, Section.start_marker())) - 1

  describe "GitLab" do
    setup do
      System.put_env(@gl_env, "tok")

      Gitlab.Config.put_active(%{
        "host" => "gitlab.com",
        "project_id" => 12_345,
        "credentials_ref" => "env:#{@gl_env}",
        "default_target_branch" => "main"
      })

      Gitlab.Budget.reset()
      desc = start_supervised!({Agent, fn -> "Worker summary" end}, id: :desc)
      round = start_supervised!({Agent, fn -> 0 end}, id: :round)

      Req.Test.stub(Gitlab.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        project = "/api/v4/projects/12345"

        case {conn.method, conn.request_path} do
          {"GET", ^project} ->
            Req.Test.json(conn, %{"visibility" => "private"})

          {"POST", p} when p == project <> "/uploads" ->
            n = Agent.get_and_update(round, &{&1, &1 + 1})

            Plug.Conn.put_status(conn, 201)
            |> Req.Test.json(%{"url" => "/uploads/h#{n}/shot.png"})

          {"GET", p} when p == project <> "/merge_requests/42" ->
            Req.Test.json(conn, %{
              "description" => Agent.get(desc, & &1),
              "sha" => "s",
              "state" => "opened"
            })

          {"PUT", p} when p == project <> "/merge_requests/42" ->
            Agent.update(desc, fn _ -> Jason.decode!(body)["description"] end)
            Req.Test.json(conn, %{})

          {"GET", p} when p == project <> "/merge_requests/42/pipelines" ->
            Req.Test.json(conn, [])

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      on_exit(fn ->
        Gitlab.Config.clear()
        System.delete_env(@gl_env)
      end)

      {:ok, desc: desc}
    end

    test "writes an inline before/after table and replaces it on the next round", %{desc: desc} do
      assert {:ok, %{rows: 1, failures: []}} = Poster.post(Gitlab, "!42", pairs("r1"), %{})
      d1 = Agent.get(desc, & &1)
      assert d1 =~ "Worker summary"

      assert d1 =~
               "| Edit modal | ![before](/uploads/h0/shot.png) | ![after](/uploads/h1/shot.png) |"

      assert markers(d1) == 1

      assert {:ok, %{failures: []}} = Poster.post(Gitlab, "!42", pairs("r2"), %{})
      d2 = Agent.get(desc, & &1)
      assert markers(d2) == 1
      assert d2 =~ "![before](/uploads/h2/shot.png)"
      refute d2 =~ "/uploads/h0/"
      assert String.starts_with?(d2, "Worker summary")
    end
  end

  describe "GitHub" do
    setup do
      System.put_env(@gh_env, "tok")

      Github.Config.put_active(%{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "env:#{@gh_env}",
        "default_target_branch" => "main"
      })

      desc = start_supervised!({Agent, fn -> "Worker summary" end}, id: :desc)
      commits = start_supervised!({Agent, fn -> 0 end}, id: :commits)
      repo = "/repos/octo/widget"

      Req.Test.stub(Github.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"GET", ^repo} ->
            Req.Test.json(conn, %{"private" => true})

          {"GET", p} when p == repo <> "/git/ref/heads/arbiter-assets" ->
            Plug.Conn.put_status(conn, 404) |> Req.Test.json(%{"message" => "Not Found"})

          {"POST", p} when p == repo <> "/git/blobs" ->
            Plug.Conn.put_status(conn, 201) |> Req.Test.json(%{"sha" => "blob"})

          {"POST", p} when p == repo <> "/git/trees" ->
            Plug.Conn.put_status(conn, 201) |> Req.Test.json(%{"sha" => "tree"})

          {"POST", p} when p == repo <> "/git/commits" ->
            n = Agent.get_and_update(commits, &{&1, &1 + 1})
            Plug.Conn.put_status(conn, 201) |> Req.Test.json(%{"sha" => "commit#{n}"})

          {"POST", p} when p == repo <> "/git/refs" ->
            Plug.Conn.put_status(conn, 201) |> Req.Test.json(%{})

          {"GET", p} when p == repo <> "/pulls/42" ->
            Req.Test.json(conn, %{
              "body" => Agent.get(desc, & &1),
              "head" => %{"sha" => "h"},
              "state" => "open"
            })

          {"PATCH", p} when p == repo <> "/pulls/42" ->
            Agent.update(desc, fn _ -> Jason.decode!(body)["body"] end)
            Req.Test.json(conn, %{})

          _ ->
            Req.Test.json(conn, [])
        end
      end)

      on_exit(fn ->
        Github.Config.clear()
        System.delete_env(@gh_env)
      end)

      {:ok, desc: desc}
    end

    test "writes an inline table of commit-pinned URLs and replaces it on the next round", %{
      desc: desc
    } do
      opts = %{task_id: "bd-1", head_sha: "aaaaaaaaaaaa1111", record: fn _ -> :ok end}

      assert {:ok, %{rows: 1, failures: []}} = Poster.post(Github, "#42", pairs("r1"), opts)
      d1 = Agent.get(desc, & &1)
      base = "https://github.com/octo/widget/blob/commit0/t/bd-1/aaaaaaaaaaaa/"
      assert d1 =~ "![before](#{base}0-before-edit.png?raw=true)"
      assert d1 =~ "![after](#{base}0-after-edit.png?raw=true)"
      assert markers(d1) == 1

      assert {:ok, %{failures: []}} = Poster.post(Github, "#42", pairs("r2"), opts)
      d2 = Agent.get(desc, & &1)
      assert markers(d2) == 1
      assert d2 =~ "/blob/commit1/"
      refute d2 =~ "/blob/commit0/"
    end
  end
end
