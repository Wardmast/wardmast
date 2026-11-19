defmodule Wardmast.Mergers.Github.AssetsBranch do
  @moduledoc """
  Writes one commit of image files onto an orphan "assets" branch through the
  GitHub Git Data API, so a PR description can embed the images by a
  commit-pinned URL (`docs/design/ui-screenshot-capture.md` §7.3).

  GitHub has no PR image-upload API; this is the hosting method the design
  chose. No clone or `git push` is involved: blobs, a tree, a commit and a ref
  update are plain REST calls with the merger's own credential, so the same
  stubbed-API tests cover it.

    * The branch is created lazily as an orphan (a commit with no parents) with
      one README and nothing else.
    * Each call adds **one commit** on the current tip, moved with a plain
      (`force: false`) ref update. A rejected update (the tip moved) re-reads
      the tip and re-applies, up to 3 attempts.
    * An orphan branch has no `.github/workflows`, so no push workflow runs; the
      commit message carries `[skip ci]` regardless.

  `req` is `(method, path, opts -> {:ok, body} | {:error, error})`, scoped to
  the API root by the caller.
  """

  @attempts 3
  @readme "# Arbiter assets\n\nMachine-generated screenshots for pull requests. Do not edit or merge.\n"

  @type file :: %{required(:path) => String.t(), required(:data) => binary()}
  @type req :: (atom(), String.t(), keyword() -> {:ok, term()} | {:error, term()})

  @doc """
  Commit `files` to `branch` of `owner/repo`; `{:ok, commit_sha}` or the first
  `{:error, reason}` (a protected branch, a failed blob, retries exhausted).
  """
  @spec push(req, String.t(), String.t(), String.t(), [file], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def push(req, owner, repo, branch, files, message) do
    root = "/repos/#{owner}/#{repo}"

    with {:ok, entries} <- blobs(req, root, files) do
      attempt(req, root, branch, entries, message, @attempts)
    end
  end

  defp attempt(req, root, branch, entries, message, left) do
    with {:ok, tip} <- tip(req, root, branch),
         {:ok, all} <- with_readme(req, root, entries, tip),
         {:ok, base_tree} <- base_tree(req, root, tip),
         {:ok, tree} <- create_tree(req, root, base_tree, all),
         {:ok, commit} <- create_commit(req, root, tree, tip, message) do
      case move_ref(req, root, branch, tip, commit) do
        :ok ->
          {:ok, commit}

        {:error, %{status: 422}} when left > 1 ->
          attempt(req, root, branch, entries, message, left - 1)

        {:error, _} = error ->
          error
      end
    end
  end

  defp blobs(req, root, files) do
    files
    |> Enum.reduce_while({:ok, []}, fn %{path: path, data: data}, {:ok, acc} ->
      case blob(req, root, data) do
        {:ok, sha} -> {:cont, {:ok, [{path, sha} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp blob(req, root, data) do
    case req.(:post, root <> "/git/blobs", json: %{"content" => Base.encode64(data), "encoding" => "base64"}) do
      {:ok, %{"sha" => sha}} -> {:ok, sha}
      {:ok, _} -> {:error, "GitHub blob response carried no sha"}
      {:error, _} = error -> error
    end
  end

  # nil tip = the branch does not exist yet.
  defp tip(req, root, branch) do
    case req.(:get, root <> "/git/ref/heads/#{branch}", []) do
      {:ok, %{"object" => %{"sha" => sha}}} -> {:ok, sha}
      {:error, %{status: 404}} -> {:ok, nil}
      {:ok, _} -> {:error, "GitHub ref response carried no sha"}
      {:error, _} = error -> error
    end
  end

  defp with_readme(_req, _root, entries, tip) when is_binary(tip), do: {:ok, entries}

  defp with_readme(req, root, entries, nil) do
    with {:ok, sha} <- blob(req, root, @readme), do: {:ok, [{"README.md", sha} | entries]}
  end


  defp base_tree(_req, _root, nil), do: {:ok, nil}

  defp base_tree(req, root, tip) do
    case req.(:get, root <> "/git/commits/#{tip}", []) do
      {:ok, %{"tree" => %{"sha" => sha}}} -> {:ok, sha}
      {:ok, _} -> {:error, "GitHub commit response carried no tree"}
      {:error, _} = error -> error
    end
  end

  defp create_tree(req, root, base_tree, entries) do
    items =
      Enum.map(entries, fn {path, sha} ->
        %{"path" => path, "mode" => "100644", "type" => "blob", "sha" => sha}
      end)

    payload =
      if base_tree,
        do: %{"base_tree" => base_tree, "tree" => items},
        else: %{"tree" => items}

    sha_of(req.(:post, root <> "/git/trees", json: payload), "tree")
  end

  defp create_commit(req, root, tree, tip, message) do
    payload = %{"message" => message, "tree" => tree, "parents" => List.wrap(tip)}
    sha_of(req.(:post, root <> "/git/commits", json: payload), "commit")
  end

  defp move_ref(req, root, branch, nil, commit) do
    payload = %{"ref" => "refs/heads/#{branch}", "sha" => commit}
    ok_or_error(req.(:post, root <> "/git/refs", json: payload))
  end

  defp move_ref(req, root, branch, _tip, commit) do
    ok_or_error(
      req.(:patch, root <> "/git/refs/heads/#{branch}", json: %{"sha" => commit, "force" => false})
    )
  end

  defp sha_of({:ok, %{"sha" => sha}}, _what), do: {:ok, sha}
  defp sha_of({:ok, _}, what), do: {:error, "GitHub #{what} response carried no sha"}
  defp sha_of({:error, _} = error, _what), do: error

  defp ok_or_error({:ok, _}), do: :ok
  defp ok_or_error({:error, _} = error), do: error
end
