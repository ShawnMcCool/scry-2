defmodule Scry2.Events.Gameplay.MulliganDecided do
  @moduledoc """
  A player made a keep or mulligan decision during the opening hand phase.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `ClientToGremessage`
  with type `ClientMessageType_MulliganResp`. Fires when the player clicks
  "Keep" or "Mulligan." The `decision` field is normalized from MTGA's
  `MulliganOption_AcceptHand` / `MulliganOption_Mulligan` to `"keep"` /
  `"mulligan"`.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the mulligan decision was made in
  - `decision` — normalized decision string: `"keep"` or `"mulligan"`

  ## Slug

  `"mulligan_decided"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:decision, :occurred_at]
  defstruct [:player_id, :mtga_match_id, :decision, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          decision: String.t(),
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      decision: payload["decision"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mulligan_decided"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
