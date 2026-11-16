defmodule Wardmast.LegacyModuleName do
  @moduledoc """
  Reads module names that were persisted before the Arbiter -> Wardmast rename
  (bd-42q5vm).

  A few rows store a module name as a string — a workflow machine's
  `workflow_module` (`inspect/1`), a PR lane's merger adapter, a resident
  author's merge overrides (`"Elixir.Arbiter.Mergers.Github"`). Table and column
  names do not change, and neither does the stored data: instead these readers
  pass the string through `normalize/1` before resolving it, so a row written
  by the previous release still names a module that exists.

  Writers always emit the current name. Drop this module (and its four call
  sites) once no install can hold a pre-rename row.
  """

  @doc "Rewrite a leading `Arbiter.` / `ArbiterWeb.` (optionally `Elixir.`-prefixed) to `Wardmast`."
  @spec normalize(term()) :: term()
  def normalize(name) when is_binary(name) do
    case Regex.run(~r/\A(Elixir\.)?Arbiter(Web)?\./, name) do
      [prefix | _] -> String.replace_prefix(name, prefix, rewritten(prefix))
      nil -> name
    end
  end

  def normalize(other), do: other

  defp rewritten(prefix), do: String.replace(prefix, "Arbiter", "Wardmast")
end
