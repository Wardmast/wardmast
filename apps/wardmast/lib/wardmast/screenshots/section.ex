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
  @type row :: %{
          required(:label) => String.t(),
          required(:before) => cell,
          required(:after) => cell
        }

  @doc "The opening marker comment."
  @spec start_marker() :: String.t()
  def start_marker, do: @start_marker

  @doc "The closing marker comment."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @default_max_chars 12_000

  @doc """
  Render `rows` as the marker-wrapped `## Screenshots` table.

  `:max_chars` (default #{@default_max_chars}) caps the section so the worker's own
  description keeps its room (GitHub's body cap is 65,536): rows that do not fit
  are dropped from the end and counted in a visible note, never silently.
  """
  @spec render([row], keyword()) :: String.t()
  def render(rows, opts \\ []) when is_list(rows) do
    max = Keyword.get(opts, :max_chars, @default_max_chars)

    head = [
      @start_marker,
      "## Screenshots",
      "",
      "| Page/state | Before | After |",
      "|---|---|---|"
    ]

    lines = Enum.map(rows, &row_line/1)

    # Reserve room for the "N more" note and the closing marker.
    budget = max - String.length(Enum.join(head, "\n")) - String.length(@end_marker) - 80
    {kept, dropped} = take_within(lines, budget)

    note =
      case dropped do
        0 -> []
        n -> ["", "_#{n} more not shown (still on the ticket)_"]
      end

    Enum.join(head ++ kept ++ note ++ [@end_marker], "\n")
  end

  defp row_line(row),
    do: "| #{escape(row.label)} | #{cell(row.before, "before")} | #{cell(row.after, "after")} |"

  defp take_within(lines, budget) do
    {kept, _used} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, used} ->
        size = String.length(line) + 1

        if used + size <= budget,
          do: {:cont, {[line | acc], used + size}},
          else: {:halt, {acc, used}}
      end)

    {Enum.reverse(kept), length(lines) - length(kept)}
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
