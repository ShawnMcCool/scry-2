defmodule Scry2.Events.Gameplay.MulliganOffered do
  @moduledoc """
  MTGA presented a mulligan decision to a player during the opening hand phase.
  One event per offer; the total number of mulligans for a game equals the count
  of these events for that game where `decision == "mulligan"`.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing a `GREMessageType_MulliganReq` message. Fires once per hand
  presented to the player. Under London mulligan rules, `hand_size` decreases
  with each successive mulligan (7, 6, 5, ...). `mtga_match_id` comes from
  `IngestRawEvents` match context state (ADR-022) since mulligan GRE messages
  don't carry a `matchID` field.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the mulligan offer occurred in
  - `seat_id` — game engine seat ID of the player being offered the mulligan
  - `hand_size` — number of cards in the offered hand (decreases each mulligan)
  - `hand_arena_ids` — arena_ids of the cards in the offered hand
  - `land_count` — number of lands in the hand (enriched at ingestion, ADR-030)
  - `nonland_count` — number of non-land cards in the hand (enriched at ingestion)
  - `total_cmc` — sum of converted mana costs of non-land cards (enriched)
  - `cmc_distribution` — map of CMC => count for non-land cards (enriched)
  - `color_distribution` — map of color symbol => count in the hand (enriched)
  - `card_names` — map of arena_id => name for cards in the hand (enriched)

  ## Slug

  `"mulligan_offered"` — stable, do not rename.
  """

  @enforce_keys [:seat_id, :hand_size, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :seat_id,
    :hand_size,
    :hand_arena_ids,
    :occurred_at,
    # Enriched at ingestion (ADR-030)
    :land_count,
    :nonland_count,
    :total_cmc,
    :cmc_distribution,
    :color_distribution,
    :card_names
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t() | nil,
          seat_id: integer(),
          hand_size: integer(),
          hand_arena_ids: [integer()] | nil,
          occurred_at: DateTime.t(),
          land_count: non_neg_integer() | nil,
          nonland_count: non_neg_integer() | nil,
          total_cmc: float() | nil,
          cmc_distribution: map() | nil,
          color_distribution: map() | nil,
          card_names: map() | nil
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mulligan_offered"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
