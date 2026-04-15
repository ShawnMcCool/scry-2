defmodule Scry2.Events.Turn.TurnStarted do
  @moduledoc """
  A new turn began.

  Event type: :state_change

  ## Source
  Produced by `IdentifyDomainEvents.GameStateMessage` from `turnInfo.turnNumber`
  changing between consecutive `GREMessageType_GameStateMessage` messages.

  ## Fields
  - `mtga_match_id` — match this turn belongs to
  - `game_number` — game within the match (1-indexed)
  - `turn_number` — MTGA turn number (increments each time active player changes)
  - `active_player_seat` — seat ID of the player whose turn it is
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :turn_number,
    :active_player_seat,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          active_player_seat: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      active_player_seat: payload["active_player_seat"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "turn_started"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
