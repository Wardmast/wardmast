defmodule Wardmast.Screenshots.Poster do
  @moduledoc """
  Posts a before/after screenshot table to a PR/MR description.

  Given image pairs it (1) hosts the images through the forge adapter
  (`Wardmast.Mergers.host_images/4`: the GitLab project uploads API, or the
  GitHub assets branch), (2) renders the `## Screenshots` table
  (`Wardmast.Screenshots.Section`) with the hosted URLs, and (3) writes it into
  the current description, replacing the table of an earlier round in place.

  An image that could not be hosted never disappears: its cell carries the
  reason (`_upload failed: …_`), the failure comes back in `failures`, and it is
  recorded through `opts[:record]` (default: the task's `:tracker_sync_failed`
  attention cause when `opts[:task_id]` is set). A UI change never ends in
  silence (`docs/design/ui-screenshot-capture.md` §8).

  A `pair` is `%{label:, before:, after:}` where each side is a
  `%{name:, data:}` image (bytes) or `{:text, reason}` (a shot that does not
  exist: `"new at this commit"`, `"capture failed: …"`).

  `opts`: `:task_id`, `:head_sha`, `:public_repo_ok`, `:assets_branch` (passed to
  the adapter), `:record` (`(String.t() -> any)`).

  The description is read-modify-written (`adapter.get/1` then
  `update_description/2`); a concurrent edit between the two is last-writer-wins.
  """

  require Logger

  alias Wardmast.Mergers
  alias Wardmast.Screenshots.Section
  alias Wardmast.Tasks.Attention

  @type result :: %{rows: non_neg_integer(), failures: [%{name: String.t(), reason: String.t()}]}

  @spec post(module(), String.t(), [map()], map()) :: {:ok, result()} | {:error, term()}
  def post(adapter, mr_ref, pairs, opts \\ %{}) when is_atom(adapter) and is_list(pairs) do
    indexed = pairs |> Enum.with_index() |> Enum.map(&index_pair/1)
    images = indexed |> Enum.flat_map(&[&1.before, &1.after]) |> Enum.filter(&image?/1)

    hosted = host(adapter, mr_ref, images, opts)
    {rows, failures} = build_rows(indexed, hosted)

    case write(adapter, mr_ref, Section.render(rows)) do
      :ok ->
        record(failures, "some screenshots could not be hosted", mr_ref, opts)
        {:ok, %{rows: length(rows), failures: failures}}

      {:error, reason} ->
        failed = [%{name: "description", reason: describe(reason)}]
        record(failed, "the screenshots table could not be written", mr_ref, opts)
        {:error, reason}
    end
  end

  # One name per image slot, so two pairs may share a file name.
  defp index_pair({pair, idx}) do
    %{
      label: pair.label,
      before: slot(pair.before, "#{idx}-before"),
      after: slot(pair.after, "#{idx}-after")
    }
  end

  defp slot(%{name: name, data: data}, prefix), do: %{name: "#{prefix}-#{name}", data: data}
  defp slot({:text, _} = text, _prefix), do: text

  defp image?(%{name: _}), do: true
  defp image?(_), do: false

  # Nothing to host is not a failure (and needs no forge call).
  defp host(_adapter, _mr_ref, [], _opts), do: {:ok, %{}}

  defp host(adapter, mr_ref, images, opts) do
    forge_opts = Map.drop(opts, [:record])

    try do
      Mergers.host_images(adapter, mr_ref, images, forge_opts)
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp build_rows(indexed, hosted) do
    {rows, failures} =
      Enum.map_reduce(indexed, [], fn pair, failures ->
        {before_cell, f1} = cell(pair.before, hosted)
        {after_cell, f2} = cell(pair.after, hosted)
        {%{label: pair.label, before: before_cell, after: after_cell}, failures ++ f1 ++ f2}
      end)

    {rows, failures}
  end

  defp cell({:text, _} = text, _hosted), do: {text, []}

  defp cell(%{name: name}, {:ok, urls}) do
    case Map.get(urls, name) do
      {:ok, url} -> {{:image, url}, []}
      {:error, reason} -> failed_cell(name, describe(reason))
      nil -> failed_cell(name, "the forge returned no URL for this image")
    end
  end

  defp cell(%{name: name}, {:error, reason}), do: failed_cell(name, describe(reason))

  defp failed_cell(name, reason),
    do: {{:text, "upload failed: #{reason}"}, [%{name: name, reason: reason}]}

  defp write(adapter, mr_ref, section) do
    with {:ok, current} <- current_description(adapter, mr_ref) do
      Mergers.update_description(adapter, mr_ref, Section.compose(current, section))
    end
  end

  defp current_description(adapter, mr_ref) do
    case adapter.get(mr_ref) do
      {:ok, %{body: body}} -> {:ok, body}
      {:ok, _} -> {:ok, nil}
      {:error, _} = error -> error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp record([], _what, _mr_ref, _opts), do: :ok

  defp record(failures, what, mr_ref, opts) do
    reasons = failures |> Enum.map(& &1.reason) |> Enum.uniq() |> Enum.join("; ")
    detail = "screenshots for #{mr_ref}: #{what}: #{reasons}"
    Logger.warning("Screenshots.Poster: #{detail}")

    case opts do
      %{record: fun} when is_function(fun, 1) -> fun.(detail)
      %{task_id: id} when is_binary(id) -> Attention.raise_cause(id, :tracker_sync_failed, detail)
      _ -> :ok
    end

    :ok
  end

  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
