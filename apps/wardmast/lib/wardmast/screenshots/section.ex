defmodule Wardmast.Screenshots.Section do
  @moduledoc """
  The `## Screenshots` section of a PR/MR description: a `Page/state | Before |
  After` table whose cells are inline images (or a short italic reason when a
  shot is missing), wrapped in marker comments Arbiter owns
  (`docs/design/ui-screenshot-capture.md` §8).

  `render/1` builds the section; `compose/2` writes it into a description,
  **replacing the existing marker block in place** (so a later round updates the
  table instead of appending a second one) and appending it when there is none.
  Both are pure.
  """

  @start_marker "<!-- arbiter:screenshots:start -->"
  @end_marker "<!-- arbiter:screenshots:end -->"
  @block ~r/<!-- arbiter:screenshots:start[^>]*-->.*?<!-- arbiter:screenshots:end -->/s

  @type cell :: {:image, String.t()} | {:text, String.t()}
  @type row :: %{required(:label) => String.t(), required(:before) => cell, required(:after) => cell}

  @doc "The opening marker comment."
  @spec start_marker() :: String.t()
  def start_marker, do: @start_marker

  @doc "The closing marker comment."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @doc "Render `rows` as the marker-wrapped `## Screenshots` table."
  @spec render([row]) :: String.t()
  def render(rows) when is_list(rows) do
    lines =
      [
        @start_marker,
        "## Screenshots",
        "",
        "| Page/state | Before | After |",
        "|---|---|---|"
      ] ++
        Enum.map(rows, fn row ->
          "| #{escape(row.label)} | #{cell(row.before, "before")} | #{cell(row.after, "after")} |"
        end) ++ [@end_marker]

    Enum.join(lines, "\n")
  end

  @doc """
  Put `section` into `body`: replace the existing marker block in place (extra
  stale blocks are dropped), or append it after the description when there is
  none. `nil` / empty `body` yields just the section.
  """
  @spec compose(String.t() | nil, String.t()) :: String.t()
  def compose(body, section) when body in [nil, ""], do: section

  def compose(body, section) when is_binary(body) do
    case Regex.split(@block, body) do
      [_only] ->
        String.trim_trailing(body) <> "\n\n" <> section

      [head | rest] ->
        String.trim_trailing(head <> section <> Enum.join(rest, ""))
    end
  end

  defp cell({:image, url}, alt), do: "![#{alt}](#{url_safe(url)})"
  defp cell({:text, reason}, _alt), do: "_#{escape(reason)}_"

  defp escape(text) do
    text
    |> to_string()
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> String.replace("|", "\\|")
  end

  # A URL inside `![](…)` must not contain a space or an unbalanced paren.
  defp url_safe(url) do
    url
    |> String.replace(" ", "%20")
    |> String.replace("(", "%28")
    |> String.replace(")", "%29")
  end
end
