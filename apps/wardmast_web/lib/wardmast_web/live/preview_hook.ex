defmodule WardmastWeb.PreviewHook do
  @moduledoc """
  `on_mount` hook that gives a LiveView app-preview state and behaviour
  (`Wardmast.Preview`), so the ticket page, the worker page and the worker list
  share one implementation instead of three copies of the same handlers.

    * `on_mount {WardmastWeb.PreviewHook, :ticket}` — for a page about one
      ticket (route param `:id` or `:task_id`). Assigns `:preview` (the
      `Wardmast.Preview.overview/1` map), `:preview_busy` and `:preview_error`,
      and handles the `"preview_start"` / `"preview_stop"` events and
      preview change notifications itself. Render with
      `WardmastWeb.PreviewPanel.preview_panel/1`.
    * `on_mount {WardmastWeb.PreviewHook, :list}` — assigns `:previews`, every
      preview, kept live; handles `"preview_stop"` with a `task_id` value.
      Render with `WardmastWeb.PreviewPanel.preview_list/1`.

  The state is read once the socket is connected (the first, static render
  shows nothing), and re-read on every preview change.

  Starting runs off the LiveView process (a checkout can take seconds), then
  reports back; the row's own transitions (starting → running / failed) arrive
  over `Wardmast.Preview.topic/0`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, start_async: 3]

  alias Wardmast.Preview

  def on_mount(:ticket, params, _session, socket) do
    task_id = params["task_id"] || params["id"]
    if connected?(socket), do: Phoenix.PubSub.subscribe(Wardmast.PubSub, Preview.topic())

    socket =
      socket
      |> assign(:preview_task_id, task_id)
      |> assign(:preview_busy, false)
      |> assign(:preview_error, nil)
      |> assign(:preview, nil)
      |> attach_hook(:preview_events, :handle_event, &ticket_event/3)
      |> attach_hook(:preview_info, :handle_info, &ticket_info/2)
      |> attach_hook(:preview_async, :handle_async, &ticket_async/3)
      |> load_async(task_id)

    {:cont, socket}
  end

  def on_mount(:list, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Wardmast.PubSub, Preview.topic())

    socket =
      socket
      |> assign(:previews, if(connected?(socket), do: load_list([]), else: []))
      |> attach_hook(:preview_list_events, :handle_event, &list_event/3)
      |> attach_hook(:preview_list_info, :handle_info, &list_info/2)

    {:cont, socket}
  end

  # The preview panel is an add-on to pages that have their own data to load;
  # a failed read here (DB busy, a crashed lookup) must leave the page up and
  # the panel at its previous state rather than take the LiveView down.
  defp load(nil, _fallback), do: nil

  defp load(task_id, fallback) do
    Preview.overview(task_id)
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  # First read, off the LiveView process: the page decides when it is ready, a
  # preview lookup must not hold up (or break) its mount.
  defp load_async(socket, nil), do: socket

  defp load_async(socket, task_id) do
    if connected?(socket),
      do: start_async(socket, :preview_load, fn -> Preview.overview(task_id) end),
      else: socket
  end

  defp ticket_async(:preview_load, {:ok, overview}, socket),
    do: {:halt, assign(socket, :preview, overview)}

  # A failed read leaves the panel as it was (the page keeps working).
  defp ticket_async(:preview_load, {:exit, _reason}, socket), do: {:halt, socket}
  defp ticket_async(_name, _result, socket), do: {:cont, socket}

  defp load_list(fallback) do
    Preview.list()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  # ---- ticket page ---------------------------------------------------------

  defp ticket_event("preview_start", _params, socket) do
    task_id = socket.assigns.preview_task_id
    lv = self()

    {:ok, _} =
      Task.Supervisor.start_child(Wardmast.TaskSupervisor, fn ->
        send(lv, {:preview_start_result, Preview.start(task_id)})
      end)

    {:halt, socket |> assign(:preview_busy, true) |> assign(:preview_error, nil)}
  end

  defp ticket_event("preview_stop", _params, socket) do
    task_id = socket.assigns.preview_task_id
    Task.Supervisor.start_child(Wardmast.TaskSupervisor, fn -> Preview.stop(task_id) end)
    {:halt, assign(socket, :preview_busy, true)}
  end

  defp ticket_event(_event, _params, socket), do: {:cont, socket}

  defp ticket_info(:previews_changed, socket) do
    {:halt,
     socket
     |> assign(:preview, load(socket.assigns.preview_task_id, socket.assigns.preview))
     |> assign(:preview_busy, false)}
  end

  defp ticket_info({:preview_start_result, result}, socket) do
    error =
      case result do
        {:ok, _} -> nil
        {:error, reason} -> reason |> Preview.error() |> elem(1)
      end

    {:halt,
     socket
     |> assign(:preview_busy, false)
     |> assign(:preview_error, error)
     |> assign(:preview, load(socket.assigns.preview_task_id, socket.assigns.preview))}
  end

  defp ticket_info(_msg, socket), do: {:cont, socket}

  # ---- list ----------------------------------------------------------------

  defp list_event("preview_stop", %{"task_id" => task_id} = params, socket) do
    repo_opts = if repo = params["repo"], do: [repo: repo], else: []

    Task.Supervisor.start_child(Wardmast.TaskSupervisor, fn ->
      Preview.stop(task_id, repo_opts)
    end)

    {:halt, socket}
  end

  defp list_event(_event, _params, socket), do: {:cont, socket}

  defp list_info(:previews_changed, socket),
    do: {:halt, assign(socket, :previews, load_list(socket.assigns.previews))}

  defp list_info(_msg, socket), do: {:cont, socket}
end
