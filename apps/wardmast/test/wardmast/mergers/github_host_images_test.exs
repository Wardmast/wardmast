defmodule Wardmast.Mergers.GithubHostImagesTest do
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.Github
  alias Wardmast.Mergers.Github.Config

  @ref "#42"
  @env_var "GTE_GITHUB_HOST_IMAGES_TOKEN"
  @repo "/repos/octo/widget"
  @opts %{task_id: "bd-abc123", head_sha: "0123456789abcdef0123"}

  @images [
    %{name: "edit__before.png", data: "PNG-BEFORE"},
    %{name: "edit__after.png", data: "PNG-AFTER"}
  ]

  setup do
    System.put_env(@env_var, "test-github-token")

    Config.put_active(%{
      "owner" => "octo",
      "repo" => "widget",
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main"
    })

    log = start_supervised!({Agent, fn -> [] end})

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    {:ok, log: log}
  end

  defp stub(fun), do: Req.Test.stub(Wardmast.Mergers.Github.HTTP, fun)
  defp json(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  # Records every request as {method, path, decoded_body} and answers through
  # `answer.(method, path, body, calls_so_far)`; unmatched calls are a test bug.
  defp stub_api(log, answer) do
    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      calls =
        Agent.get_and_update(log, fn l -> {l, l ++ [{conn.method, conn.request_path, body}]} end)

      case answer.(conn.method, conn.request_path, body, calls) do
        {status, payload} -> json(conn, status, payload)
      end
    end)
  end

  defp calls(log), do: Agent.get(log, & &1)

  defp base_answer(method, path, body, calls, tip) do
    case {method, path} do
      {"GET", @repo} ->
        {200, %{"private" => true, "visibility" => "private"}}

      {"GET", @repo <> "/git/ref/heads/arbiter-assets"} ->
        if tip,
          do: {200, %{"object" => %{"sha" => tip}}},
          else: {404, %{"message" => "Not Found"}}

      {"GET", @repo <> "/git/commits/" <> sha} when sha == tip ->
        {200, %{"sha" => sha, "tree" => %{"sha" => "tree-of-tip"}}}

      {"POST", @repo <> "/git/blobs"} ->
        n = Enum.count(calls, fn {m, p, _} -> m == "POST" and p == @repo <> "/git/blobs" end)
        {201, %{"sha" => "blob#{n}"}}

      {"POST", @repo <> "/git/trees"} ->
        {201, %{"sha" => "newtree", "echo" => body}}

      {"POST", @repo <> "/git/commits"} ->
        {201, %{"sha" => "commitsha1"}}

      {"POST", @repo <> "/git/refs"} ->
        {201, %{"ref" => "refs/heads/arbiter-assets"}}

      {"PATCH", @repo <> "/git/refs/heads/arbiter-assets"} ->
        {200, %{"object" => %{"sha" => "commitsha1"}}}
    end
  end

  test "creates the orphan assets branch and returns commit-pinned raw URLs", %{log: log} do
    stub_api(log, &base_answer(&1, &2, &3, &4, nil))

    assert {:ok, results} = Github.host_images(@ref, @images, @opts)

    base = "https://github.com/octo/widget/blob/commitsha1/t/bd-abc123/0123456789ab/"

    assert results == %{
             "edit__before.png" => {:ok, base <> "edit__before.png?raw=true"},
             "edit__after.png" => {:ok, base <> "edit__after.png?raw=true"}
           }

    log = calls(log)

    blobs = for {"POST", @repo <> "/git/blobs", b} <- log, do: b
    assert Enum.map(blobs, & &1["encoding"]) == ["base64", "base64", "base64"]
    assert Base.encode64("PNG-BEFORE") in Enum.map(blobs, & &1["content"])

    {"POST", _, tree} = Enum.find(log, &match?({"POST", @repo <> "/git/trees", _}, &1))
    refute Map.has_key?(tree, "base_tree")
    paths = Enum.map(tree["tree"], & &1["path"])
    assert "README.md" in paths
    assert "t/bd-abc123/0123456789ab/edit__before.png" in paths

    {"POST", _, commit} = Enum.find(log, &match?({"POST", @repo <> "/git/commits", _}, &1))
    assert commit["parents"] == []
    assert commit["message"] =~ "bd-abc123"
    assert commit["message"] =~ "[skip ci]"

    {"POST", _, ref} = Enum.find(log, &match?({"POST", @repo <> "/git/refs", _}, &1))
    assert ref == %{"ref" => "refs/heads/arbiter-assets", "sha" => "commitsha1"}
  end

  test "adds one commit on top of an existing assets branch with a plain fast-forward", %{
    log: log
  } do
    stub_api(log, &base_answer(&1, &2, &3, &4, "tipsha"))

    assert {:ok, %{"edit__after.png" => {:ok, url}}} = Github.host_images(@ref, @images, @opts)
    assert url =~ "/blob/commitsha1/"

    log = calls(log)
    {"POST", _, tree} = Enum.find(log, &match?({"POST", @repo <> "/git/trees", _}, &1))
    assert tree["base_tree"] == "tree-of-tip"
    refute "README.md" in Enum.map(tree["tree"], & &1["path"])

    {"POST", _, commit} = Enum.find(log, &match?({"POST", @repo <> "/git/commits", _}, &1))
    assert commit["parents"] == ["tipsha"]

    {"PATCH", _, ref} = Enum.find(log, &match?({"PATCH", _, _}, &1))
    assert ref == %{"sha" => "commitsha1", "force" => false}
  end

  test "a rejected (non-fast-forward) push re-fetches the tip and tries again", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      patches = Enum.count(calls, fn {m, _, _} -> m == "PATCH" end)

      if method == "PATCH" and patches == 0 do
        {422, %{"message" => "Update is not a fast forward"}}
      else
        base_answer(method, path, body, calls, "tipsha")
      end
    end)

    assert {:ok, %{"edit__after.png" => {:ok, _}}} = Github.host_images(@ref, @images, @opts)
    assert Enum.count(calls(log), &match?({"PATCH", _, _}, &1)) == 2
  end

  test "a push that keeps being rejected surfaces the reason after 3 attempts", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      if method == "PATCH",
        do: {422, %{"message" => "Update is not a fast forward"}},
        else: base_answer(method, path, body, calls, "tipsha")
    end)

    assert {:error, reason} = Github.host_images(@ref, @images, @opts)
    assert inspect(reason) =~ "fast forward"
    assert Enum.count(calls(log), &match?({"PATCH", _, _}, &1)) == 3
  end

  test "a protected branch refusing the push is an error, not a silent skip", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      if method == "POST" and path == @repo <> "/git/refs",
        do: {403, %{"message" => "Protected branch rule violations"}},
        else: base_answer(method, path, body, calls, nil)
    end)

    assert {:error, reason} = Github.host_images(@ref, @images, @opts)
    assert inspect(reason) =~ "Protected branch"
  end

  test "a failed blob upload fails the set with a reason", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      if method == "POST" and path == @repo <> "/git/blobs",
        do: {500, %{"message" => "boom"}},
        else: base_answer(method, path, body, calls, nil)
    end)

    assert {:error, reason} = Github.host_images(@ref, @images, @opts)
    assert inspect(reason) =~ "boom"
  end

  test "a public repo is blocked unless public_repo_ok is set; nothing is pushed", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      if method == "GET" and path == @repo,
        do: {200, %{"private" => false, "visibility" => "public"}},
        else: base_answer(method, path, body, calls, nil)
    end)

    assert {:error, :public_repo_blocked} = Github.host_images(@ref, @images, @opts)
    assert calls(log) == [{"GET", @repo, nil}]

    assert {:ok, _} = Github.host_images(@ref, @images, Map.put(@opts, :public_repo_ok, true))
  end

  test "an unreadable repo fails closed", %{log: log} do
    stub_api(log, fn _, _, _, _ -> {403, %{"message" => "Forbidden"}} end)
    assert {:error, :public_repo_blocked} = Github.host_images(@ref, @images, @opts)
  end

  test "a custom assets branch is honoured", %{log: log} do
    stub_api(log, fn method, path, body, calls ->
      path = String.replace(path, "my-assets", "arbiter-assets")
      {s, payload} = base_answer(method, path, body, calls, nil)
      {s, payload}
    end)

    assert {:ok, _} =
             Github.host_images(@ref, @images, Map.put(@opts, :assets_branch, "my-assets"))

    {"POST", _, ref} =
      Enum.find(calls(log), &match?({"POST", @repo <> "/git/refs", _}, &1))

    assert ref["ref"] == "refs/heads/my-assets"
  end

  test "get_description/1 reads just the PR body", %{log: log} do
    stub_api(log, fn "GET", "/repos/octo/widget/pulls/42", _, _ ->
      {200, %{"body" => "pr body"}}
    end)

    assert {:ok, "pr body"} = Github.get_description(@ref)
    assert [{"GET", "/repos/octo/widget/pulls/42", nil}] = calls(log)
  end

  test "get_description/1 is nil for an empty body and an error when unreadable", %{log: log} do
    stub_api(log, fn _, _, _, _ -> {200, %{"body" => nil}} end)
    assert {:ok, nil} = Github.get_description(@ref)

    stub_api(log, fn _, _, _, _ -> {404, %{"message" => "Not Found"}} end)
    assert {:error, _} = Github.get_description(@ref)
  end
end
