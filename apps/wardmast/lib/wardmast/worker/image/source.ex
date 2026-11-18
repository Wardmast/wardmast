defmodule Wardmast.Worker.Image.Source do
  @moduledoc """
  Which image a run placed on a node takes, chosen per run (SI4,
  `docs/design/remote-workers.md` §21.2.1, §21.6). Every node runs the published,
  digest-pinned image; build-from-plan on a node was retired in SI13.

    * `:registry` — a cluster (`caps.image = "registry"`, no `caps.image_sources`). The
      primary publishes and sends the pinned `ref`; the cluster pulls with its own pull
      secrets (KH13).
    * `{:pull, %{auth, level, insecure?}}` — a machine node whose agent lists `"registry"`
      in `caps.image_sources`, for a repo whose registry has a pull credential that node
      may hold (`Wardmast.Worker.Image.PullCredential`, the reach rule of §21.4). The
      primary publishes and sends the pinned `ref`, the image's CLI set and `pull_auth`.
    * `{:error, reason}` — the node cannot take the published image (an agent that lists
      no `registry` source, or a repo with no pull credential the node may hold). The run
      is not placed on it; there is no plan to fall back to.

  Options: `PullCredential.for_node/4`'s.
  """

  alias Wardmast.Worker.Image.PullCredential

  @type t :: :registry | {:pull, PullCredential.t()} | {:error, term()}

  @doc "Whether `node` only runs registry images (`caps.image = \"registry\"`)."
  @spec registry_only?(map()) :: boolean()
  def registry_only?(node), do: caps(node)["image"] == "registry"

  @doc "Whether `node`'s agent can pull a published image (`caps.image_sources`)."
  @spec pulls?(map()) :: boolean()
  def pulls?(node) do
    case caps(node)["image_sources"] do
      sources when is_list(sources) -> "registry" in sources
      _ -> false
    end
  end

  @doc """
  Where `node`'s worker images come from, for the doctor and the nodes page:
  `"registry"` for a node that can take the published image (a cluster, or a machine
  whose agent lists `registry`), else `"build"` (an agent too old to pull: it takes no
  runs). Whether a given run pulls also depends on the repo's pull credential (`choose/3`).
  """
  @spec node_source(map()) :: String.t()
  def node_source(node) do
    if registry_only?(node) or pulls?(node), do: "registry", else: "build"
  end

  @doc """
  The source for a run of `ctx.repo` in `ctx.workspace` (`ctx` is the publish
  context, or any map with those keys) placed on `node` (a placement row).
  """
  @spec choose(map(), map(), keyword()) :: t()
  def choose(node, ctx, opts \\ []) do
    cond do
      pulls?(node) -> pull(node, ctx, opts)
      registry_only?(node) -> :registry
      true -> {:error, :node_cannot_pull}
    end
  end

  defp pull(node, ctx, opts) do
    case PullCredential.for_node(Map.get(ctx, :workspace), Map.get(ctx, :repo), node, opts) do
      {:ok, pull} -> {:pull, pull}
      {:error, reason} -> {:error, reason}
    end
  end

  defp caps(node), do: Map.get(node, :caps) || %{}
end
