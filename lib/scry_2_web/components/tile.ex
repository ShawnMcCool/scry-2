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

  import Scry2Web.CoreComponents

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
        "bg-base-200/50 p-5 min-h-[200px] no-underline",
        "transition-colors hover:border-primary/30 hover:bg-base-200"
      ]}
    >
      <.kind_label :if={@spec.kind_label}>{@spec.kind_label}</.kind_label>

      <div class="flex gap-4 items-start">
        <img
          :if={art_kind(@spec.art) == :card_image}
          src={"/images/cards/#{@spec.art[:arena_id]}"}
          alt={@spec.art[:name] || ""}
          class="w-20 h-auto rounded shadow-lg ring-1 ring-base-content/10 flex-shrink-0"
          loading="lazy"
        />
        <div class="space-y-1 min-w-0 flex-1">
          <div class="tile-title font-beleren text-2xl leading-tight text-base-content">
            {@spec.title}
          </div>
          <div :if={@spec.body} class="tile-subtitle text-sm text-base-content/70 leading-snug">
            {@spec.body}
          </div>
          <div :if={art_kind(@spec.art) == :deck_colors} class="pt-1">
            <.mana_pips colors={@spec.art[:colors]} class="text-base" />
          </div>
        </div>
      </div>

      <div class="flex-1"></div>

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
        "bg-base-200/50 p-5 min-h-[240px] no-underline",
        "transition-colors hover:border-primary/30 hover:bg-base-200"
      ]}
    >
      <div class="tile-kind-row flex items-center gap-2">
        <.kind_label :if={@spec.kind_label}>{@spec.kind_label}</.kind_label>
        <.sample_pill :if={@spec.badge == :tier_2} tone={:warning}>tier 2</.sample_pill>
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

  defp art_kind(%{type: type}) when is_atom(type), do: type
  defp art_kind(%{kind: kind}) when is_atom(kind), do: kind
  defp art_kind(_), do: nil
end
