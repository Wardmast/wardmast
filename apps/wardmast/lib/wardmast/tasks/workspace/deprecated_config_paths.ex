defmodule Wardmast.Tasks.Workspace.DeprecatedConfigPaths do
  @moduledoc """
  Deprecated workspace-config roots and the canonical path each one stands for
  (bd-4j0nfe).

  `sandbox` is the only one: the sandbox is read from `agent.security.sandbox`
  (`Wardmast.Agents.SecurityPolicy`) and from nowhere else. A root `sandbox` key
  used to be refused, and `force` stored it as dead config that
  `arb config get sandbox` showed as if it were live, while runs kept the
  canonical backend. It is now an alias: a write is rewritten onto the canonical
  path (`Wardmast.Tasks.Workspace.Changes.RewriteDeprecatedConfigPaths`) and a
  stored root key is folded in on boot (`Wardmast.Boot.ConfigMigrator`).

  When both are present the **canonical value wins**: folding a stored config
  never changes the backend a workspace already runs, and a patch naming both
  keeps the explicit canonical value.
  """

  alias Wardmast.Tasks.Workspace.Changes.PatchConfig
  alias Wardmast.Tasks.Workspace.ConfigPath

  @aliases %{"sandbox" => ["agent", "security", "sandbox"]}

  @typedoc "A deprecated dotted leaf path and the canonical path it was written to."
  @type rewrite :: {deprecated :: String.t(), canonical :: String.t()}

  @doc "The deprecated root keys."
  @spec roots() :: [String.t()]
  def roots, do: Map.keys(@aliases)

  @doc """
  The canonical dotted path for `path`, or `nil` when `path` is not under a
  deprecated root: `"sandbox.backend"` gives `"agent.security.sandbox.backend"`,
  `"agent.security.sandbox.backend"` gives `nil`.
  """
  @spec canonical_path(String.t()) :: String.t() | nil
  def canonical_path(path) when is_binary(path) do
    case ConfigPath.split(path) do
      [root | rest] when is_map_key(@aliases, root) ->
        ConfigPath.join(Map.fetch!(@aliases, root) ++ rest)

      _ ->
        nil
    end
  end

  @doc """
  Move every deprecated root in `config` (a stored config or a patch) onto its
  canonical path. The canonical value wins a collision. Returns the rewritten
  map and one `t:rewrite/0` per leaf moved (empty when nothing was deprecated).
  """
  @spec fold(map()) :: {map(), [rewrite()]}
  def fold(config) when is_map(config) do
    Enum.reduce(@aliases, {config, []}, fn {root, canonical}, {acc, rewrites} ->
      case Map.pop(acc, root) do
        {nil, _} ->
          {acc, rewrites}

        {value, rest} ->
          # `deep_merge(left, right)` lets `right` win, so the deprecated value
          # is the LEFT operand: an existing canonical value is kept.
          moved = PatchConfig.deep_merge(ConfigPath.put(%{}, canonical, value), rest)
          {moved, rewrites ++ leaf_rewrites(value, [root], canonical)}
      end
    end)
  end

  @doc "The deprecation warning for one rewrite, as logged and returned to callers."
  @spec warning(rewrite()) :: String.t()
  def warning({deprecated, canonical}),
    do:
      "`#{deprecated}` is deprecated and read by nothing; using `#{canonical}`, the key runs read"

  @doc "Rewrite one dotted `unset_paths` entry onto its canonical path."
  @spec rewrite_path(String.t()) :: {String.t(), [rewrite()]}
  def rewrite_path(path) when is_binary(path) do
    case canonical_path(path) do
      nil -> {path, []}
      canonical -> {canonical, [{path, canonical}]}
    end
  end

  defp leaf_rewrites(%{} = map, prefix, canonical) when map_size(map) > 0 do
    Enum.flat_map(map, fn {k, v} ->
      leaf_rewrites(v, prefix ++ [to_string(k)], canonical ++ [to_string(k)])
    end)
  end

  defp leaf_rewrites(_leaf, prefix, canonical),
    do: [{ConfigPath.join(prefix), ConfigPath.join(canonical)}]
end
