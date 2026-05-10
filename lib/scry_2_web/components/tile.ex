defmodule Scry2Web.Tile do
  @moduledoc """
  Universal homepage tile renderer. Pattern-matches on
  `spec.composition` to dispatch to the activity (α tease) or insight
  (γ mini-page) layout.

  Consumes a `%Scry2.Showcase.TileSpec{}` produced by
  `Scry2.Showcase.Homepage.tiles/1`. The whole tile is wrapped in a
  navigating link to `spec.target`. Sample-size and confidence badges
  are part of the design language, not footnotes — they live in the
  meta line.
  """

  use Phoenix.Component

  alias Scry2.Showcase.TileSpec

  attr :spec, :any, required: true, doc: "a %Scry2.Showcase.TileSpec{}"

  def tile(%{spec: %TileSpec{composition: :activity}} = assigns) do
    {:navigate, target} = assigns.spec.target
    assigns = assign(assigns, :target, target)

    ~H"""
    <.link
      navigate={@target}
      class={[
        "tile group relative flex flex-col gap-3 rounded-lg border border-base-content/10",
        "bg-base-200/50 p-4 min-h-[200px] no-underline",
        "transition-colors hover:border-primary/30 hover:bg-base-200"
      ]}
    >
      <div
        :if={@spec.kind_label}
        class="tile-kind-label text-[10px] uppercase tracking-[0.10em] font-semibold text-primary/85"
      >
        {@spec.kind_label}
      </div>

      <div class="tile-art flex-1 min-h-[80px] rounded bg-gradient-to-br from-primary/15 to-secondary/8 relative overflow-hidden">
        <div
          :if={@spec.art == nil}
          class="absolute inset-3 rounded bg-gradient-to-b from-amber-700/20 to-amber-950/10"
          aria-hidden="true"
        >
        </div>
      </div>

      <div class="tile-title font-beleren text-base leading-snug text-base-content">
        {@spec.title}
      </div>

      <div
        :if={@spec.meta != []}
        class="tile-meta text-[11px] text-base-content/55 flex flex-wrap items-center gap-x-2 gap-y-1"
      >
        <%= for {item, index} <- Enum.with_index(@spec.meta) do %>
          <span :if={index > 0} class="text-base-content/25" aria-hidden="true">·</span>
          <span>{item}</span>
        <% end %>
      </div>
    </.link>
    """
  end

  def tile(%{spec: %TileSpec{composition: :insight}} = assigns) do
    {:navigate, target} = assigns.spec.target
    assigns = assign(assigns, :target, target)

    ~H"""
    <.link
      navigate={@target}
      class={[
        "tile group relative flex flex-col gap-2 rounded-lg border border-base-content/10",
        "bg-base-200/50 p-4 min-h-[240px] no-underline",
        "transition-colors hover:border-primary/30 hover:bg-base-200"
      ]}
    >
      <div class="tile-kind-row flex items-center gap-2">
        <div
          :if={@spec.kind_label}
          class="text-[10px] uppercase tracking-[0.10em] font-semibold text-primary/85"
        >
          {@spec.kind_label}
        </div>
        <span
          :if={@spec.badge == :tier_2}
          class="text-[9px] uppercase tracking-wide bg-warning/12 text-warning border border-warning/30 rounded px-1.5 py-0.5 font-mono"
        >
          tier 2
        </span>
      </div>

      <div class="tile-title font-beleren text-base leading-snug text-base-content">
        {@spec.title}
      </div>

      <div :if={@spec.body} class="tile-body text-xs text-base-content/75 leading-relaxed">
        {@spec.body}
      </div>

      <div
        :if={@spec.stats && @spec.stats != []}
        class="tile-stats mt-auto grid grid-cols-3 gap-2 rounded bg-base-content/[0.03] p-2"
      >
        <div :for={stat <- @spec.stats} class="flex flex-col">
          <span class="font-beleren text-sm leading-tight text-base-content">{stat["num"]}</span>
          <span class="text-[9px] uppercase tracking-wide text-base-content/50">{stat["lbl"]}</span>
        </div>
      </div>

      <div
        :if={@spec.meta != []}
        class="tile-meta text-[11px] text-base-content/55 flex flex-wrap items-center gap-x-2 gap-y-1"
      >
        <%= for {item, index} <- Enum.with_index(@spec.meta) do %>
          <span :if={index > 0} class="text-base-content/25" aria-hidden="true">·</span>
          <span>{item}</span>
        <% end %>
      </div>
    </.link>
    """
  end
end
