defmodule Scry2Web.Components.RevealedCardsCard do
  @moduledoc """
  Renders the per-match Chain-2 revealed-cards section on the match
  detail page.

  Per-seat groups (You / Opponent / others), each with per-zone
  rows (Battlefield first; followed by Hand, Graveyard, and Exile). Each card is rendered via `Scry2Web.CardComponents.card_image/1`
  so the existing image cache + tooltip behaviour is reused.

  Hidden when `groups` is empty.

  Logic-bearing helpers live in `Scry2Web.Live.MatchBoardView` per
  ADR-013 — this module is template wiring only.
  """

  use Phoenix.Component

  alias Scry2Web.CardComponents

  attr :groups, :list, required: true, doc: "Output of `MatchBoardView.group_by_seat_and_zone/1`."
  attr :card_names_by_arena_id, :map, default: %{}

  def card(assigns) do
    ~H"""
    <div :if={@groups != []} class="card bg-base-200 shadow-sm" data-test="revealed-cards-card">
      <div class="card-body p-4">
        <h3 class="card-title text-sm uppercase tracking-wide opacity-70">
          Revealed cards
        </h3>
        <p class="text-xs opacity-60 -mt-1 mb-2">
          Cards visible in MTGA's process memory at end-of-match.
        </p>

        <div class="flex flex-col gap-4">
          <.seat_group
            :for={{group, group_idx} <- Enum.with_index(@groups)}
            group_idx={group_idx}
            seat_label={group.label}
            zones={group.zones}
            card_names_by_arena_id={@card_names_by_arena_id}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :group_idx, :integer, required: true
  attr :seat_label, :string, required: true
  attr :zones, :list, required: true
  attr :card_names_by_arena_id, :map, default: %{}

  defp seat_group(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <span class="text-xs uppercase tracking-wide opacity-50">{@seat_label}</span>

      <div :for={zone <- @zones} class="flex flex-col gap-1">
        <div class="flex items-baseline gap-2">
          <span class="text-xs font-semibold opacity-70">{zone.label}</span>
          <span class="text-xs opacity-50 tabular-nums">({length(zone.arena_ids)})</span>
          <span :if={zone.zone_id == 3} class="text-xs opacity-50 italic">
            revealed only
          </span>
        </div>

        <div class="flex flex-wrap gap-1">
          <CardComponents.card_image
            :for={{arena_id, idx} <- Enum.with_index(zone.arena_ids)}
            id={"revealed-#{@group_idx}-#{zone.zone_id}-#{idx}-#{arena_id}"}
            arena_id={arena_id}
            name={Map.get(@card_names_by_arena_id, arena_id, "Card ##{arena_id}")}
            class="w-[3.5rem]"
          />
        </div>
      </div>
    </div>
    """
  end
end
