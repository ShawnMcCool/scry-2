defmodule Scry2Web.Components.RevealedCardsCard do
  @moduledoc """
  Renders the per-match Chain-2 revealed-cards section on the match
  detail page.

  Per-seat groups (You / Opponent / others), each with per-zone rows
  (Battlefield first; followed by Hand, Graveyard, and Exile). The zone
  headers are domain chrome; each zone's card row is a
  `Scry2Web.DeckRendering.deck_view/1` in memory order (`order:
  :natural` — the reader reports cards as they sit in MTGA's process
  memory).

  Hidden when `groups` is empty.

  Logic-bearing helpers live in `Scry2Web.Live.MatchBoardView` per
  ADR-013 — this module is template wiring only.
  """

  use Phoenix.Component

  import Scry2Web.DeckRendering, only: [deck_view: 1]

  alias Scry2Web.DeckRendering.ViewSpec

  attr :groups, :list, required: true, doc: "Output of `MatchBoardView.group_by_seat_and_zone/1`."

  attr :cards_by_arena_id, :map,
    default: %{},
    doc: "Card reference lookup — `Scry2.Cards.list_by_arena_ids/1`."

  attr :cached_ids, :any,
    default: nil,
    doc: "`@cached_card_ids` from `Scry2Web.CardImages`."

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
            cards_by_arena_id={@cards_by_arena_id}
            cached_ids={@cached_ids}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :group_idx, :integer, required: true
  attr :seat_label, :string, required: true
  attr :zones, :list, required: true
  attr :cards_by_arena_id, :map, default: %{}
  attr :cached_ids, :any, default: nil

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

        <.deck_view
          id={"revealed-#{@group_idx}-#{zone.zone_id}"}
          spec={%ViewSpec{piling: :spread, order: :natural, card_width: "3.5rem"}}
          cards={zone.arena_ids}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_ids}
        />
      </div>
    </div>
    """
  end
end
