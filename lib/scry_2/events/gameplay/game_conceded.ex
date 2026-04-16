defmodule Scry2.Events.Gameplay.GameConceded do
  @moduledoc """
  A player conceded the current game.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `ClientToGremessage`
  with type `ClientMessageType_ConcedeReq`. Fires when the player clicks
  "Concede" and the message is sent to the game engine.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the concession occurred in
  - `scope` — concession scope: `"game"` to concede the current game,
    `"match"` to concede the entire match

  ## Slug

  `"game_conceded"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :game_number, :scope, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: integer() | nil,
          scope: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      scope: payload["scope"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "game_conceded"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
