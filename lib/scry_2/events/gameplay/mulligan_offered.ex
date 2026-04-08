defmodule Scry2.Events.Gameplay.MulliganOffered do
  @moduledoc """
  Domain event — MTGA offered a mulligan decision to a player during
  the opening hand phase. One event per mulligan offer. The number of
  mulligans for a game is the count of these events for that game.

  ## Slug

  `"mulligan_offered"` — stable, do not rename.

  ## Source

  Produced from `GreToClientEvent` containing a
  `GREMessageType_MulliganReq` message. The `hand_size` decreases with
  each successive mulligan (7, 6, 5, ...) under London mulligan rules.

  `mtga_match_id` comes from IngestRawEvents match_context state
  (ADR-022) since mulligan GRE diffs don't carry matchID.
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
