defmodule WardmastWeb.AttachmentsPanel do
  @moduledoc """
  The ATTACHMENTS panel of a ticket page (`Wardmast.Attachments`, bd-5hlegn).

  Takes the groups `Wardmast.Attachments.pairs/1` returns: a `before` and an
  `after` that share a shot render **side by side** in one `#attachment-pair-<key>`
  block; every other image is a single tile. A pruned image (retention deleted
  its blob) is a placeholder that keeps the caption and provenance, not a broken
  `<img>`.
  """

  use WardmastWeb, :html

  alias WardmastWeb.CoreComponents.Core

  attr :groups, :list, required: true, doc: "`Wardmast.Attachments.pairs/1`"
  attr :class, :any, default: nil

  def attachments_panel(assigns) do
    assigns = assign(assigns, :count, length(assigns.groups))

    ~H"""
    <Core.panel id="panel-attachments" title="ATTACHMENTS" meta={meta(@groups)} class={@class}>
      <div id="attachments-list" class="flex flex-col gap-4">
        <%= for group <- @groups do %>
          <%= case group do %>
            <% %{kind: :pair} -> %>
              <.pair group={group} />
            <% %{kind: :single, attachment: att} -> %>
              <div class="max-w-md">
                <.tile attachment={att} />
              </div>
          <% end %>
        <% end %>
      </div>
    </Core.panel>
    """
  end

  attr :group, :map, required: true

  defp pair(assigns) do
    ~H"""
    <figure
      id={"attachment-pair-#{pair_dom(@group.key)}"}
      data-layout="side-by-side"
      class="m-0 flex flex-col gap-2"
    >
      <figcaption class="text-[11px] uppercase tracking-wide text-[var(--text-label)]">
        {pair_title(@group.key)}
      </figcaption>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div data-role="before" class="flex flex-col gap-1 min-w-0">
          <span class="text-[11px] font-semibold text-[var(--text-label)]">BEFORE</span>
          <.tile attachment={@group.before} pair?={true} />
        </div>
        <div data-role="after" class="flex flex-col gap-1 min-w-0">
          <span class="text-[11px] font-semibold text-[var(--text-label)]">AFTER</span>
          <.tile attachment={@group.after} pair?={true} />
        </div>
      </div>
    </figure>
    """
  end

  attr :attachment, :map, required: true
  attr :pair?, :boolean, default: false

  # A pair member keeps its own id too, namespaced so the "not a loose tile"
  # selector (`#attachment-<id>`) stays false for it.
  defp tile(assigns) do
    ~H"""
    <div
      id={
        if(@pair?, do: "attachment-in-pair-#{@attachment.id}", else: "attachment-#{@attachment.id}")
      }
      data-pruned={if(@attachment.pruned_at, do: "")}
      class="flex flex-col gap-1 min-w-0"
    >
      <%= if @attachment.pruned_at do %>
        <div class="flex items-center justify-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-default)] bg-[var(--surface-sunken)] px-3 py-6 text-[12px] italic text-[var(--text-label)]">
          Pruned by retention
        </div>
      <% else %>
        <a href={~p"/attachments/#{@attachment.id}"} target="_blank" rel="noopener">
          <img
            src={~p"/attachments/#{@attachment.id}"}
            alt={@attachment.caption || @attachment.filename || "attachment"}
            width={@attachment.width}
            height={@attachment.height}
            loading="lazy"
            class="block max-w-full h-auto rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-sunken)] transition-opacity hover:opacity-90"
          />
        </a>
      <% end %>
      <span :if={@attachment.caption} class="text-[12px] text-[var(--text-secondary)]">
        {@attachment.caption}
      </span>
      <span class="text-[11px] text-[var(--text-label)] tabular-nums">
        {@attachment.source} · {@attachment.width}×{@attachment.height} · {format_bytes(
          @attachment.byte_size
        )}
      </span>
    </div>
    """
  end

  defp meta(groups) do
    images =
      Enum.reduce(groups, 0, fn
        %{kind: :pair}, acc -> acc + 2
        %{kind: :single}, acc -> acc + 1
      end)

    "#{images} #{if images == 1, do: "image", else: "images"}"
  end

  defp pair_dom({shot, viewport, theme}),
    do: [shot, viewport, theme] |> Enum.reject(&is_nil/1) |> Enum.join("-")

  defp pair_title({shot, viewport, theme}),
    do: [shot, viewport, theme] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
