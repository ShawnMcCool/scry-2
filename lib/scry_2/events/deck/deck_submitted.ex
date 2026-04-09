defmodule Scry2.Events.Deck.DeckSubmitted do
  @moduledoc """
  A deck was submitted for a game. Carries the full main deck and sideboard
  composition as arena_ids, as reported by the game engine at game start.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `GreToClientEvent` containing `GREMessageType_ConnectResp`. The ConnectResp
  carries `connectResp.deckMessage.deckCards` as a flat array of arena_ids
  (repeated for copies). Fires at the start of each game within a match.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — MTGA match identifier linking this submission to a match
  - `mtga_deck_id` — MTGA deck identifier (may be nil for sealed pools)
  - `game_number` — which game within the match (1, 2, 3) this deck was submitted for
  - `main_deck` — list of `%{arena_id, count}` entries for the main deck
  - `sideboard` — list of `%{arena_id, count}` entries for the sideboard
  - `deck_colors` — derived color identity string, enriched at ingestion (ADR-030)

  ## Slug

  `"deck_submitted"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :main_deck, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :mtga_deck_id,
    :game_number,
    :main_deck,
    :sideboard,
    :occurred_at,
    # Enriched at ingestion (ADR-030)
    :deck_colors
  ]

  @type card_count :: %{arena_id: integer(), count: pos_integer()}

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t() | nil,
          mtga_deck_id: String.t() | nil,
          game_number: pos_integer() | nil,
          main_deck: [card_count()],
          sideboard: [card_count()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_submitted"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
