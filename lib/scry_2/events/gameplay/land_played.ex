defmodule Scry2.Events.Gameplay.LandPlayed do
  @moduledoc """
  A land was played from hand to the battlefield.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation with category
  `PlayLand`. Fires once per land drop — does not fire for lands entering
  via other means (e.g. put-into-play effects, which produce `ZoneChanged`).

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the land play occurred in
  - `turn_number` — turn number when the land was played
  - `phase` — game phase (should be main phase)
  - `active_player` — seat ID of the player playing the land
  - `owner_seat_id` — seat that owns the zone the card moved into,
    from the GRE zone table. `nil` for shared zones (battlefield,
    stack) which have no owner. Distinct from `active_player`,
    which is merely whose turn it is.
  - `owner_is_local` — whether `owner_seat_id` is the local player's seat.
    GRE seat ids are per-match numbers and the local player alternates
    seats, so consumers need this role rather than the raw number.
    `nil` when the local seat is unknown.
  - `zone_from` — semantic zone the card left, resolved through
    `Scry2.Events.IdentifyDomainEvents.ZoneTable`
  - `zone_to` — semantic zone the card entered
  - `card_arena_id` — arena_id of the land played
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"land_played"` — stable, do not rename.
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
    :owner_seat_id,
    :owner_is_local,
    :zone_from,
    :zone_to,
    :card_arena_id,
    :card_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          owner_seat_id: integer() | nil,
          owner_is_local: boolean() | nil,
          zone_from: String.t() | nil,
          zone_to: String.t() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      active_player: payload["active_player"],
      owner_seat_id: payload["owner_seat_id"],
      owner_is_local: payload["owner_is_local"],
      zone_from: payload["zone_from"],
      zone_to: payload["zone_to"],
      card_arena_id: payload["card_arena_id"],
      card_name: payload["card_name"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "land_played"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
