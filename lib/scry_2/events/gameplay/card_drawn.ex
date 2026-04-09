defmodule Scry2.Events.Gameplay.CardDrawn do
  @moduledoc """
  A card was drawn to a player's hand during a game.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing a `GREMessageType_GameStateMessage` with a draw annotation.
  Fires each time the game engine records a card moving from library to hand.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the draw occurred in
  - `turn_number` — turn number when the card was drawn
  - `phase` — game phase during which the draw occurred
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the drawn card
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"card_drawn"` — stable, do not rename.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
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
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "card_drawn"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
