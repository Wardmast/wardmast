defmodule WardmastWeb.PreviewPanel do
  @moduledoc """
  The app-preview UI (`Wardmast.Preview`): `preview_panel/1` for one ticket's
  page and `preview_list/1` for the global list of previews. State and events
  come from `WardmastWeb.PreviewHook`.
  """

  use WardmastWeb, :html

  alias WardmastWeb.CoreComponents.Core

  attr :preview, :map, required: true, doc: "`Wardmast.Preview.overview/1`"
  attr :busy, :boolean, default: false
  attr :error, :string, default: nil
  attr :class, :any, default: nil

  @doc "The Preview panel of a ticket: button, state, URL, log tail on failure, Stop."
  def preview_panel(assigns) do
    assigns = assign(assigns, :row, assigns.preview.row)

    ~H"""
    <Core.panel id="panel-preview" title="PREVIEW" meta={@preview.repo} class={@class}>
      <div
        id="preview-state"
        data-status={(@row && @row.status) || "none"}
        class="flex flex-col gap-3"
      >
        <%= cond do %>
          <% @row && @row.status == "starting" -> %>
            <div class="flex items-center gap-3">
              <span id="preview-starting" class="text-[12.5px] text-[var(--text-secondary)]">
                Starting preview<span :if={@row.port}> on port {@row.port}</span>…
              </span>
              <Core.button
                id="preview-stop-btn"
                phx-click="preview_stop"
                variant="secondary"
                size="sm"
                disabled={@busy}
              >
                Stop
              </Core.button>
            </div>
          <% @row && @row.status == "running" -> %>
            <div class="flex flex-wrap items-center gap-3">
              <span class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
                running
              </span>
              <a
                id="preview-url"
                href={@row.url}
                target="_blank"
                rel="noopener noreferrer"
                class="font-mono text-[12.5px] text-[var(--text-link,var(--text-title))] underline underline-offset-2"
              >
                {@row.url}
              </a>
              <Core.button
                id="preview-stop-btn"
                phx-click="preview_stop"
                variant="danger"
                size="sm"
                disabled={@busy}
              >
                Stop
              </Core.button>
            </div>
          <% @row && @row.status == "failed" -> %>
            <div class="flex flex-col gap-2">
              <p id="preview-error" class="text-[12.5px] text-[var(--text-danger,var(--text-title))]">
                Preview failed: {@row.error}
              </p>
              <pre
                :if={@preview.log_tail not in [nil, ""]}
                id="preview-log-tail"
                class="max-h-64 overflow-auto rounded-[var(--radius-panel)] bg-[var(--arb-canvas-sunken)] p-3 text-[11.5px] font-mono whitespace-pre-wrap"
              >{@preview.log_tail}</pre>
              <div class="flex items-center gap-3">
                <Core.button
                  id="preview-start-btn"
                  phx-click="preview_start"
                  variant="secondary"
                  size="sm"
                  disabled={@busy}
                >
                  Retry
                </Core.button>
                <Core.button
                  id="preview-dismiss-btn"
                  phx-click="preview_stop"
                  variant="secondary"
                  size="sm"
                  disabled={@busy}
                >
                  Dismiss
                </Core.button>
              </div>
            </div>
          <% @preview.configured? -> %>
            <div class="flex items-center gap-3">
              <Core.button
                id="preview-start-btn"
                phx-click="preview_start"
                variant="primary"
                size="sm"
                disabled={@busy}
              >
                Preview
              </Core.button>
              <span class="text-[12px] text-[var(--text-secondary)]">
                Run this ticket's checkout as a live app on its own port.
              </span>
            </div>
          <% true -> %>
            <p id="preview-unconfigured" class="text-[12px] text-[var(--text-secondary)]">
              No preview configured for
              <code class="font-mono">{@preview.repo || "this ticket's repo"}</code>
              — set <code class="font-mono">worker.repos.&lt;repo&gt;.preview.command</code>.
            </p>
        <% end %>

        <p
          :if={@row && @row.checkout_note}
          id="preview-checkout-note"
          class="text-[11.5px] text-[var(--text-secondary)]"
        >
          {@row.checkout_note}
        </p>
        <p
          :if={@error}
          id="preview-start-error"
          class="text-[12.5px] text-[var(--text-danger,var(--text-title))]"
        >
          {@error}
        </p>
      </div>
    </Core.panel>
    """
  end

  attr :previews, :list, required: true, doc: "`Wardmast.Preview.list/0` rows"
  attr :class, :any, default: nil

  @doc "The global list of previews, with a Stop button per row."
  def preview_list(assigns) do
    ~H"""
    <Core.panel
      :if={@previews != []}
      id="panel-previews"
      title="PREVIEWS"
      meta={"#{length(@previews)} app(s)"}
      class={@class}
    >
      <ul id="previews-list" class="flex flex-col divide-y divide-[var(--border-default)]">
        <li
          :for={p <- @previews}
          id={"preview-row-#{p.repo}-#{p.task_id}"}
          class="flex flex-wrap items-center gap-3 py-2 first:pt-0 last:pb-0"
        >
          <.link
            navigate={~p"/tasks/#{p.task_id}"}
            class="font-mono text-[12px] text-[var(--text-title)]"
          >
            {p.task_id}
          </.link>
          <span class="text-[11px] text-[var(--text-label)] font-mono">{p.repo}</span>
          <span class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
            {p.status}
          </span>
          <a
            :if={p.url}
            href={p.url}
            target="_blank"
            rel="noopener noreferrer"
            class="font-mono text-[12px] underline underline-offset-2"
          >
            {p.url}
          </a>
          <span :if={p.status == "failed"} class="text-[12px] text-[var(--text-secondary)] truncate">
            {p.error}
          </span>
          <span class="ml-auto">
            <Core.button
              id={"preview-stop-#{p.repo}-#{p.task_id}"}
              phx-click="preview_stop"
              phx-value-task_id={p.task_id}
              phx-value-repo={p.repo}
              variant="secondary"
              size="sm"
            >
              Stop
            </Core.button>
          </span>
        </li>
      </ul>
    </Core.panel>
    """
  end
end
