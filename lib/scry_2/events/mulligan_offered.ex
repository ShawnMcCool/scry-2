defmodule Scry2.Events.MulliganOffered do
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
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t() | nil,
          seat_id: integer(),
          hand_size: integer(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mulligan_offered"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
