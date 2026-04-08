defmodule Scry2.Events.Gameplay.MulliganDecided do
  @moduledoc """
  Domain event — a player made an explicit keep or mulligan decision.

  ## Slug

  `"mulligan_decided"` — stable, do not rename.

  ## Source

  Produced from `ClientToGremessage` raw events with type
  `ClientMessageType_MulliganResp`. The `decision` field is normalized
  from MTGA's `MulliganOption_AcceptHand` / `MulliganOption_Mulligan`
  to `"keep"` / `"mulligan"`.
  """

  @enforce_keys [:decision, :occurred_at]
  defstruct [:player_id, :mtga_match_id, :decision, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          decision: String.t(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mulligan_decided"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
