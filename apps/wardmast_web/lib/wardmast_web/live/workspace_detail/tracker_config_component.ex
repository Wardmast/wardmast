defmodule WardmastWeb.WorkspaceDetail.TrackerConfigComponent do
  @moduledoc """
  `tracker.config.*` — the adapter-specific fields for whichever tracker type
  is currently selected.

  The type comes in as `@type_preview` rather than being read from config: the
  policy form live-updates it on change, so the operator sees the right fields
  before saving the type. Only the selected adapter's fields are written, which
  is what lets a saved type's config survive while another type is selected.
  """
  use WardmastWeb, :live_component

  import WardmastWeb.WorkspaceDetail.Rows
  import WardmastWeb.WorkspaceDetail.Shared

  alias Wardmast.Trackers.Connection
  alias Wardmast.Trackers.DeviceFlow
  alias WardmastWeb.CoreComponents.Core
  alias WardmastWeb.CoreComponents.Forms

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:tracker_config_error, nil)
     |> assign(:connection, nil)
     |> assign(:device, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, :secret_keys, secret_keys(socket.assigns.workspace))}
  end

  # The form's second submit button (`tracker_config[action]=test`) runs the
  # connection test against the *unsaved* values instead of saving them, so a
  # credential can be proven before it is committed.
  @impl true
  def handle_event(
        "save_tracker_config",
        %{"tracker_config" => %{"action" => "test"} = params},
        socket
      ) do
    ws = socket.assigns.workspace
    overrides = params |> Map.drop(["action"]) |> Map.take(connection_fields(params["type"], ws))

    {:noreply,
     socket
     |> assign(:connection, :testing)
     |> start_async(:connection_test, fn -> Connection.test(ws, overrides) end)}
  end

  def handle_event("save_tracker_config", %{"tracker_config" => params}, socket) do
    type = params["type"] || cfg(socket.assigns.workspace, ["tracker", "type"], "none")
    {patch, unset} = tracker_config_patch(type, params)

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws, "Tracker config saved.")
         |> assign(:tracker_config_error, nil)}

      {:error, msg} ->
        {:noreply, assign(socket, :tracker_config_error, msg)}
    end
  end

  def handle_event("start_device_flow", params, socket) do
    ws = socket.assigns.workspace
    type = socket.assigns.type_preview

    if DeviceFlow.supported?(type) and device_idle?(socket.assigns.device) do
      provider = String.to_existing_atom(type)
      tracker_config = cfg(ws, ["tracker", "config"], %{})
      client_id = get_in(params, ["device", "client_id"])

      {:noreply,
       socket
       |> assign(:device, %{status: :starting, provider: provider})
       |> start_async(:device_start, fn ->
         DeviceFlow.start(provider, client_id: client_id, tracker_config: tracker_config)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_device_flow", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:device_start)
     |> cancel_async(:device_poll)
     |> assign(:device, nil)}
  end

  @impl true
  def handle_async(:connection_test, {:ok, result}, socket),
    do: {:noreply, assign(socket, :connection, result)}

  def handle_async(:connection_test, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :connection, {:error, "The connection test crashed."})}

  def handle_async(:device_start, {:ok, {:ok, %DeviceFlow{} = flow}}, socket) do
    provider = flow.provider
    sleep = Application.get_env(:wardmast, :device_flow_sleep, &Process.sleep/1)

    {:noreply,
     socket
     |> assign(:device, %{
       status: :waiting,
       provider: provider,
       user_code: flow.user_code,
       url: flow.verification_uri,
       url_complete: flow.verification_uri_complete
     })
     |> start_async(:device_poll, fn -> DeviceFlow.await(flow, sleep: sleep) end)}
  end

  def handle_async(:device_start, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, :device, device_error(socket, message))}

  def handle_async(:device_start, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:device_start, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :device, device_error(socket, "Could not start the flow."))}

  # The token goes straight from the poll result into the vault: it is bound
  # to a local for exactly one `set_secrets/2` call and never assigned, so it
  # cannot reach a render, a diff or a crash dump of the socket.
  def handle_async(:device_poll, {:ok, {:ok, token}}, socket) do
    ws = socket.assigns.workspace
    provider = socket.assigns.device.provider
    key = "#{provider}_oauth_token"

    case set_secrets(ws, %{key => token}) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws, "Authorized — token stored as secret:#{key}.")
         |> point_credentials_at(key)
         |> assign(:secret_keys, secret_keys(ws))
         |> assign(:device, %{status: :done, provider: provider, secret: "secret:#{key}"})}

      {:error, message} ->
        {:noreply,
         assign(socket, :device, device_error(socket, "Could not store the token: #{message}"))}
    end
  end

  def handle_async(:device_poll, {:ok, {:error, failure}}, socket) do
    provider = socket.assigns.device.provider

    {:noreply,
     assign(socket, :device, device_error(socket, DeviceFlow.describe_error(failure, provider)))}
  end

  def handle_async(:device_poll, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:device_poll, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :device, device_error(socket, "Polling stopped unexpectedly."))}

  defp device_idle?(nil), do: true
  defp device_idle?(%{status: status}), do: status in [:done, :error]

  defp device_error(socket, message) do
    provider = socket.assigns.device && socket.assigns.device.provider
    %{status: :error, provider: provider, error: message}
  end

  # Only fills an *empty* credentials_ref: an operator who already pointed the
  # tracker at env:/secret: credentials keeps them until they choose to switch.
  defp point_credentials_at(socket, key) do
    ws = socket.assigns.workspace

    if tracker_cfg(ws, "credentials_ref") == "" do
      patch = %{"tracker" => %{"config" => %{"credentials_ref" => "secret:#{key}"}}}

      case patch_config(ws, patch, []) do
        {:ok, ws} -> apply_workspace(socket, ws)
        {:error, _} -> socket
      end
    else
      socket
    end
  end

  # The form fields a connection test may override: this adapter's own, plus
  # the type and credentials_ref — never anything else a crafted payload names.
  defp connection_fields(type, ws) do
    type = type || cfg(ws, ["tracker", "type"], "none")
    ["type", "credentials_ref" | tracker_adapter_fields(type) |> Enum.map(&elem(&1, 0))]
  end

  # The plain string/select fields each adapter's `Config.resolve/0` actually
  # reads out of `tracker.config` (see `apps/wardmast/lib/wardmast/trackers/
  # {jira,shortcut,linear,github,gitlab}/config.ex`). `credentials_ref` is
  # common to every adapter and rendered separately as a secret select, so it
  # isn't listed here.
  # `{field, label, consequence}` — the consequence is what the field *does*,
  # not what it is called, because the label alone never tells an operator
  # whether leaving it blank is safe.
  defp tracker_adapter_fields("jira") do
    [
      {"host", "Host", "the Jira site issues are read from and written back to"},
      {"project_key", "Project key", "new issues are filed under this project"},
      {"email", "Email", "the account the API token belongs to; blank uses token-only auth"}
    ]
  end

  defp tracker_adapter_fields("shortcut") do
    [
      {"workflow_id", "Workflow ID",
       "new stories land in this workflow; blank uses the org's default"}
    ]
  end

  defp tracker_adapter_fields("linear") do
    [
      {"team_id", "Team ID", "issues are created on this team; blank uses the token's default"},
      {"org_url_key", "Org URL key", "used to build the issue links shown on the board"},
      {"base_url", "Base URL", "point at a self-hosted API; blank uses linear.app"}
    ]
  end

  defp tracker_adapter_fields("github") do
    [
      {"owner", "Owner", "the account or org whose issues this workspace syncs"},
      {"repo", "Repo", "the repository issues are read from and filed in"},
      {"base_url", "Base URL", "point at a GitHub Enterprise API; blank uses github.com"}
    ]
  end

  defp tracker_adapter_fields("gitlab") do
    [
      {"host", "Host", "the GitLab instance issues are read from and written back to"},
      {"project_id", "Project ID or path", "the project issues are read from and filed in"}
    ]
  end

  defp tracker_adapter_fields(_type), do: []

  defp provider_label("github"), do: "GitHub"
  defp provider_label("gitlab"), do: "GitLab"
  defp provider_label(_), do: ""

  defp provider_atom("github"), do: :github
  defp provider_atom("gitlab"), do: :gitlab
  defp provider_atom(_), do: nil

  defp tracker_cfg(ws, field) do
    case cfg(ws, ["tracker", "config", field]) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  # Builds the `tracker.config` patch/unset for the currently-selected
  # adapter's fields only — the config underneath every *other* tracker type
  # is untouched, so `patch_config`'s deep-merge preserves it and switching
  # `tracker.type` back and forth doesn't discard it.
  defp tracker_config_patch(type, params) do
    fields = tracker_adapter_fields(type) |> Enum.map(&elem(&1, 0))
    fields = if type == "none", do: fields, else: fields ++ ["credentials_ref"]

    {patch, unset} =
      Enum.reduce(fields, {%{}, []}, fn field, {patch, unset} ->
        case blank_to_nil(params[field]) do
          nil -> {patch, unset ++ ["tracker.config.#{field}"]}
          v -> {Map.put(patch, field, v), unset}
        end
      end)

    {%{"tracker" => %{"config" => patch}}, unset}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-4">
      <.form
        id="tracker-config-form"
        for={%{}}
        as={:tracker_config}
        phx-submit="save_tracker_config"
        phx-target={@myself}
      >
        <input type="hidden" name="tracker_config[type]" value={@type_preview} />
        <.rows>
          <.setting_row
            :for={{field, label, consequence} <- tracker_adapter_fields(@type_preview)}
            name={label}
            consequence={consequence}
          >
            <:control>
              <Forms.input
                name={"tracker_config[#{field}]"}
                value={tracker_cfg(@workspace, field)}
                size="sm"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>

          <.setting_row
            name="Credentials"
            consequence="tracker.config.credentials_ref — which stored secret the adapter authenticates with; add one under Secrets first"
          >
            <:control>
              <Forms.select
                name="tracker_config[credentials_ref]"
                options={
                  credentials_ref_options(@secret_keys, tracker_cfg(@workspace, "credentials_ref"))
                }
                value={tracker_cfg(@workspace, "credentials_ref")}
                size="sm"
                class="w-[240px]"
              />
            </:control>
          </.setting_row>
        </.rows>

        <div class="mt-3 flex items-center gap-3">
          <Core.button type="submit" variant="primary" size="sm">Save tracker config</Core.button>
          <Core.button
            type="submit"
            id="test-tracker-connection"
            name="tracker_config[action]"
            value="test"
            variant="ghost"
            size="sm"
            disabled={@connection == :testing}
          >
            {if @connection == :testing, do: "Testing…", else: "Test connection"}
          </Core.button>
          <p :if={@tracker_config_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
            {@tracker_config_error}
          </p>
        </div>

        <p
          :if={match?({:ok, _}, @connection)}
          id="tracker-connection-result"
          data-status="ok"
          class="mt-2 mb-0 text-[11px] text-[var(--arb-ok-text)]"
        >
          Connected as {elem(@connection, 1).identity}.
        </p>
        <p
          :if={match?({:error, _}, @connection)}
          id="tracker-connection-result"
          data-status="error"
          class="mt-2 mb-0 text-[11px] text-[var(--arb-fail-text)]"
        >
          {elem(@connection, 1)}
        </p>
      </.form>

      <.rows :if={DeviceFlow.supported?(@type_preview)}>
        <.setting_row
          name={"Authorize with #{provider_label(@type_preview)}"}
          consequence="approve Wardmast in your browser with a one-time code; the token is stored as a secret and never shown. Or paste a personal access token under Secrets."
        >
          <:control>
            <.form
              :if={device_idle?(@device)}
              id="device-flow-form"
              for={%{}}
              as={:device}
              phx-submit="start_device_flow"
              phx-target={@myself}
              class="flex items-center gap-2"
            >
              <Forms.input
                name="device[client_id]"
                value=""
                size="sm"
                class="w-[200px]"
                placeholder={
                  if DeviceFlow.configured_client_id(provider_atom(@type_preview)),
                    do: "OAuth client ID (server default)",
                    else: "OAuth client ID"
                }
                autocomplete="off"
              />
              <Core.button type="submit" size="sm">Authorize</Core.button>
            </.form>
            <Core.button
              :if={@device && @device.status in [:starting, :waiting]}
              type="button"
              id="device-flow-cancel"
              variant="ghost"
              size="sm"
              phx-click="cancel_device_flow"
              phx-target={@myself}
            >
              Cancel
            </Core.button>
          </:control>
          <:below>
            <div
              :if={@device}
              id="device-flow-status"
              data-status={@device.status}
              class="flex flex-col gap-2 rounded-[var(--radius-chip)] border border-solid border-[var(--border-default)] px-3 py-2 text-[12px] text-[var(--text-body)]"
            >
              <p :if={@device.status == :starting} class="m-0">Requesting a code…</p>
              <div :if={@device.status == :waiting} class="flex flex-col gap-1">
                <p class="m-0">
                  Open
                  <a
                    id="device-flow-url"
                    href={@device.url_complete || @device.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="underline"
                  >
                    {@device.url}
                  </a>
                  and enter this code:
                </p>
                <code
                  id="device-flow-code"
                  class="w-fit select-all font-[family-name:var(--font-mono)] text-[18px] tracking-[0.2em] text-[var(--text-title)]"
                >
                  {@device.user_code}
                </code>
                <p class="m-0 text-[11px] text-[var(--text-label)]">
                  Waiting for approval — this page checks automatically.
                </p>
              </div>
              <p :if={@device.status == :done} class="m-0 text-[var(--arb-ok-text)]">
                Authorized. Token stored as <code>{@device.secret}</code>.
              </p>
              <p :if={@device.status == :error} class="m-0 text-[var(--arb-fail-text)]">
                {@device.error}
              </p>
            </div>
          </:below>
        </.setting_row>
      </.rows>

      <p class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]">
        Picking another tracker type under Policy swaps these fields; a saved type's config is kept
        while another is selected, so switching back doesn't lose it. Blank unsets a field.
      </p>
    </div>
    """
  end
end
