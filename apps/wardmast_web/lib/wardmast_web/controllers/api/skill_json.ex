defmodule WardmastWeb.Api.SkillJSON do
  @moduledoc """
  Render functions for `Wardmast.Skills.Skill` resources. The shapes live in
  `Wardmast.Skills.Serializer`, shared with the MCP tools (parity audit P-22):
  a list omits `body`, a single skill carries it.
  """

  alias Wardmast.Skills.Serializer

  def index(%{skills: skills}), do: %{data: Serializer.summaries(skills)}

  # `show` optionally carries a non-fatal bundled-collision warning (create /
  # update); it is omitted entirely when there is no collision.
  def show(%{skill: skill} = assigns) do
    case Map.get(assigns, :warning) do
      nil -> Serializer.full(skill)
      warning -> Map.put(Serializer.full(skill), :warning, warning)
    end
  end
end
