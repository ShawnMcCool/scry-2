defmodule Scry2.Matches.RevealedCardsProjection do
  @moduledoc """
  Projects card-identity disclosures from the domain event log into
  `matches_revealed_cards` — the read model behind the match page's
  **Revealed cards** section.

  ## What counts as a reveal

  Every zone-transfer domain event carries the arena_id MTGA disclosed to
  the local client, the seat that owns the destination zone, and the
  resolved semantic zone. MTGA only ever sends a `grpId` for a card whose
  identity the client has been shown, so an event with a resolved
  `card_arena_id` *is* the reveal — no heuristic filter is needed.

  ## Shape

  One row per `(match, seat, arena_id)`. `current_zone` tracks the most
  recent zone the card was seen in, so the projection is cumulative
  across the whole match rather than a single instant — a card revealed
  on turn 3 and exiled on turn 5 is still recorded.

  Replaces the Chain-2 memory walker's board snapshot, which read MTGA's
  card-display objects and reported cards that were never in the match.
  See [ADR-047](../../../decisions/architecture/2026-09-25-047-revealed-cards-from-domain-events.md).
  """
  use Scry2.Events.Projector,
    claimed_slugs:
      ~w(card_drawn card_exiled land_played spell_cast spell_resolved permanent_destroyed zone_changed),
    projection_tables: [Scry2.Matches.RevealedCard]

  alias Scry2.Matches

  # Zones that describe where a card *is*. Transitions into bookkeeping
  # zones still count as a reveal, but must not overwrite a meaningful
  # current_zone with "limbo".
  @bookkeeping_zones ~w(limbo pending suppressed)

  defp project(%{card_arena_id: arena_id} = event) when is_integer(arena_id) do
    case reveal_from(event) do
      nil -> :ok
      attrs -> Matches.record_revealed_card!(attrs)
    end
  end

  defp project(_event), do: :ok

  # A reveal needs a match and an owning seat. Events whose zone transfer
  # touched only shared zones carry no owner and are skipped rather than
  # guessed onto a seat.
  defp reveal_from(%{mtga_match_id: match_id, owner_seat_id: seat_id} = event)
       when is_binary(match_id) and is_integer(seat_id) do
    %{
      mtga_match_id: match_id,
      seat_id: seat_id,
      is_local: Map.get(event, :owner_is_local),
      arena_id: event.card_arena_id,
      current_zone: meaningful_zone(Map.get(event, :zone_to)),
      turn_number: Map.get(event, :turn_number)
    }
  end

  defp reveal_from(_event), do: nil

  defp meaningful_zone(zone) when zone in @bookkeeping_zones, do: nil
  defp meaningful_zone(zone), do: zone
end
