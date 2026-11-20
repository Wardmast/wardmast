defmodule Wardmast.Tasks.Workspace.Changes.RewriteDeprecatedConfigPaths do
  @moduledoc """
  First change on `:patch_config` (bd-4j0nfe): rewrites a deprecated root in
  `patch` and `unset_paths` onto its canonical path
  (`Wardmast.Tasks.Workspace.DeprecatedConfigPaths`) before anything else reads
  them, so the CLI, REST and MCP all write the key the server actually reads.

  `arb config set sandbox.backend auto` used to be refused, and with `force` it
  stored a root `sandbox` key nothing reads while runs kept the canonical
  backend. Now it sets `agent.security.sandbox.backend`, validated there, and a
  root `sandbox` key can no longer be stored, `force` or not.

  Each rewritten leaf is logged as a deprecation warning and returned as the
  updated record's `:config_deprecations` metadata (`[{deprecated, canonical}]`)
  so a caller can show the warning to whoever made the write.
  """

  use Ash.Resource.Change

  require Logger

  alias Ash.Changeset
  alias Wardmast.Tasks.Workspace.DeprecatedConfigPaths

  @impl true
  def change(changeset, _opts, _context) do
    {patch, patch_rewrites} = rewrite_patch(Changeset.get_argument(changeset, :patch))
    {unsets, unset_rewrites} = rewrite_unsets(Changeset.get_argument(changeset, :unset_paths))

    case patch_rewrites ++ unset_rewrites do
      [] ->
        changeset

      rewrites ->
        Enum.each(rewrites, &log/1)

        changeset
        |> Changeset.set_argument(:patch, patch)
        |> Changeset.set_argument(:unset_paths, unsets)
        |> Changeset.after_action(fn _changeset, record ->
          {:ok, Ash.Resource.put_metadata(record, :config_deprecations, rewrites)}
        end)
    end
  end

  defp rewrite_patch(%{} = patch), do: DeprecatedConfigPaths.fold(patch)
  defp rewrite_patch(other), do: {other, []}

  defp rewrite_unsets(paths) when is_list(paths) do
    {rewritten, rewrites} =
      paths
      |> Enum.map(fn
        path when is_binary(path) -> DeprecatedConfigPaths.rewrite_path(path)
        other -> {other, []}
      end)
      |> Enum.unzip()

    {rewritten, List.flatten(rewrites)}
  end

  defp rewrite_unsets(other), do: {other, []}

  defp log({deprecated, canonical}) do
    Logger.warning(
      "workspace config: `#{deprecated}` is deprecated and read by nothing; " <>
        "wrote `#{canonical}` instead (bd-4j0nfe)"
    )
  end
end
