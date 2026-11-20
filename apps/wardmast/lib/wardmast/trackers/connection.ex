defmodule Wardmast.Trackers.Connection do
  @moduledoc """
  "Does this tracker config actually authenticate?" — the dashboard's
  connection test.

  It calls the selected adapter's `current_user/0` (a cheap authenticated
  read on every adapter: `GET /user`, a `viewer` query, …) against the
  workspace's *saved* tracker config with the operator's unsaved form values
  laid over it, so a credential can be proven before it is saved.

  The result is `{:ok, %{type:, identity:}}` or `{:error, message}`, where the
  message is the tracker's own error text. Every stored secret value is
  scrubbed out of that text first: a provider that echoes a rejected token back
  in its error body must not carry it to the page.
  """

  alias Wardmast.Redaction
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Trackers

  @type result :: {:ok, %{type: String.t(), identity: String.t()}} | {:error, String.t()}

  @doc """
  Test `workspace`'s tracker. `overrides` is a map of string `tracker.config`
  fields (plus an optional `"type"`); a blank value unsets the saved one, the
  same as saving the form would.
  """
  @spec test(Workspace.t(), map()) :: result()
  def test(%Workspace{} = workspace, overrides \\ %{}) do
    {type, workspace} = apply_overrides(workspace, overrides)

    case Trackers.workspace_type(workspace) do
      :none ->
        {:error, "No tracker selected — pick a tracker type and save before testing."}

      type_atom ->
        adapter = Trackers.for_workspace(workspace)

        Trackers.with_workspace(type_atom, workspace, fn ->
          adapter.current_user()
        end)
        |> format(type, workspace)
    end
  end

  defp format({:ok, identity}, type, _ws) when is_binary(identity),
    do: {:ok, %{type: type, identity: identity}}

  defp format({:error, :not_supported}, type, _ws),
    do: {:error, "The #{type} tracker can't be tested — it has no authenticated identity."}

  defp format({:error, reason}, _type, ws), do: {:error, scrub(message(reason), ws)}
  defp format(other, _type, ws), do: {:error, scrub("unexpected result: #{inspect(other)}", ws)}

  defp message(%{message: message}) when is_binary(message), do: message
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp scrub(text, ws) do
    values = ws |> Workspace.secrets_map() |> Map.values() |> Enum.filter(&is_binary/1)
    text |> Redaction.redact(values) |> Redaction.redact_patterns()
  end

  # Mirrors the dashboard form's save: blank → unset, else set.
  defp apply_overrides(%Workspace{config: config} = workspace, overrides) do
    config = config || %{}
    saved_type = get_in(config, ["tracker", "type"]) || "none"
    type = non_blank(overrides["type"]) || saved_type

    fields = Map.delete(overrides, "type")

    tracker_config =
      Enum.reduce(fields, get_in(config, ["tracker", "config"]) || %{}, fn {k, v}, acc ->
        case non_blank(v) do
          nil -> Map.delete(acc, k)
          v -> Map.put(acc, k, v)
        end
      end)

    config = Map.put(config, "tracker", %{"type" => type, "config" => tracker_config})
    {type, %{workspace | config: config}}
  end

  defp non_blank(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp non_blank(_), do: nil
end
