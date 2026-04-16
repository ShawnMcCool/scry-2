defmodule Scry2.Events.Gameplay.TokenCreated do
  @moduledoc """
  A token creature or token permanent was created during a game.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an annotation for token creation (a zone transfer to the
  battlefield for a newly created game object). Fires when any effect
  creates a token.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the token was created in
  - `turn_number` — turn number when the token was created
  - `phase` — game phase during which the token was created
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the token's template card
  - `card_name` — resolved token name (enriched at ingestion)

  ## Slug

  `"token_created"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :turn_number,
    :phase,
    :active_player,
    :card_arena_id,
    :card_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      active_player: payload["active_player"],
      card_arena_id: payload["card_arena_id"],
      card_name: payload["card_name"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "token_created"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
