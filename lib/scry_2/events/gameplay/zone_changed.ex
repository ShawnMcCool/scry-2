defmodule Scry2.Events.Gameplay.ZoneChanged do
  @moduledoc """
  A card moved between zones by a means not covered by a more specific event.
  Catch-all for zone transitions that are not a land play, spell cast, spell
  resolution, card draw, exile, permanent destruction, or token creation.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation that does not match
  any of the more specific zone-change categories. Fires for sacrifices,
  discard, mill, return-to-hand effects, and other zone transitions.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the zone change occurred in
  - `turn_number` — turn number when the card changed zones
  - `phase` — game phase during which the zone change occurred
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the card that moved
  - `card_name` — resolved card name (enriched at ingestion)
  - `reason` — raw MTGA category string describing the cause of the zone change
  - `zone_from` — zone the card moved from (e.g. `"Battlefield"`, `"Hand"`)
  - `zone_to` — zone the card moved to (e.g. `"Graveyard"`, `"Library"`)

  ## Slug

  `"zone_changed"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :turn_number,
    :phase,
    :active_player,
    :card_arena_id,
    :card_name,
    :reason,
    :zone_from,
    :zone_to,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          reason: String.t() | nil,
          zone_from: String.t() | nil,
          zone_to: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      active_player: payload["active_player"],
      card_arena_id: payload["card_arena_id"],
      card_name: payload["card_name"],
      reason: payload["reason"],
      zone_from: payload["zone_from"],
      zone_to: payload["zone_to"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "zone_changed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
