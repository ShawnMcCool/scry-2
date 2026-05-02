defmodule Scry2Web.RecentCraftsCard do
  @moduledoc """
  Recent-crafts list card on the Economy page.

  Renders one row per detected wildcard craft:
  card image · card name · soft rarity chip · quantity (when > 1) ·
  relative timestamp.

  Empty state explains the forward-only nature of the feature
  (crafts can only be detected from the first memory snapshot
  onwards — see ADR-037).
  """

  use Phoenix.Component

  import Scry2Web.CardComponents
  import Scry2Web.CoreComponents
  import Scry2Web.LiveHelpers

  attr :crafts, :list, required: true
  attr :cards_by_arena_id, :map, required: true

  def recent_crafts_card(assigns) do
    ~H"""
    <section :if={@crafts != []}>
      <h2 class="text-lg font-semibold mb-3 font-beleren">Recent Crafts</h2>
      <ul class="rounded-lg border border-base-content/5 divide-y divide-base-content/5">
        <li :for={craft <- @crafts} class="flex items-center gap-4 px-4 py-3">
          <.card_image
            arena_id={craft.arena_id}
            id={"craft-img-#{craft.id}"}
            class="w-10"
            name={card_name_for(@cards_by_arena_id, craft.arena_id)}
          />

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 font-medium truncate">
              {card_name_for(@cards_by_arena_id, craft.arena_id) ||
                "Unknown card ##{craft.arena_id}"}
              <span :if={craft.quantity > 1} class="text-base-content/50 text-xs">
                ×{craft.quantity}
              </span>
            </div>
            <div class="flex items-center gap-2 text-xs text-base-content/50 mt-0.5">
              <span class={[
                "inline-flex items-center gap-1 px-2 py-0.5 rounded",
                rarity_chip_class(craft.rarity)
              ]}>
                <.wildcard_icon rarity={craft.rarity} class="size-3" />
                {String.capitalize(craft.rarity)} wildcard
              </span>
              <span aria-hidden="true">·</span>
              <span>{relative_time(craft.occurred_at_upper)}</span>
            </div>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Resolves a card's display name from an arena_id, or `nil` when the
  card isn't in the lookup map.
  """
  @spec card_name_for(map(), integer()) :: String.t() | nil
  def card_name_for(cards_by_arena_id, arena_id) when is_map(cards_by_arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      nil -> nil
      %{name: name} -> name
      %{"name" => name} -> name
      _ -> nil
    end
  end

  @doc """
  Soft chip background per rarity. Pairs the existing wildcard color
  with a low-alpha variant so the chip doesn't compete with the row
  text. Per memory `feedback_soft_ui_states`.
  """
  @spec rarity_chip_class(String.t()) :: String.t()
  def rarity_chip_class("common"), do: "bg-base-content/5 text-base-content/70"
  def rarity_chip_class("uncommon"), do: "bg-blue-500/10 text-blue-400"
  def rarity_chip_class("rare"), do: "bg-amber-500/10 text-amber-400"
  def rarity_chip_class("mythic"), do: "bg-red-500/10 text-red-400"
  def rarity_chip_class(_), do: "bg-base-content/5 text-base-content/70"
end
