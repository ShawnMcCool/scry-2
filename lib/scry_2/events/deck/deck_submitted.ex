defmodule Scry2.Events.Deck.DeckSubmitted do
  @moduledoc """
  Domain event — a deck was submitted for a match. Carries the full main
  deck + sideboard composition as arena_ids.

  ## Slug

  `"deck_submitted"` — stable, do not rename.

  ## Source (future)

  Will be produced by `Scry2.Events.IdentifyDomainEvents` from one of two raw
  MTGA sources:

    * `GreToClientEvent.greToClientMessages[]` with type
      `"GREMessageType_ConnectResp"` — carries `connectResp.deckMessage.deckCards`
      as a flat array of arena_ids (repeated for copies). Covers both
      self and opponent decks.
    * `EventSetDeckV2` / `DeckUpsertDeckV2` — lobby events, self deck only,
      carry a pre-aggregated structure.

  See `TODO.md` > "Match ingestion follow-ups" > Deck submissions for
  the full plan including how `mtga_deck_id` is derived.

  ## Projected by (future)

  `Scry2.Matches.MatchProjection` will project to `matches_deck_submissions`
  via `Scry2.Matches.upsert_deck_submission!/1`, keyed on `mtga_deck_id`.

  ## Status

  Struct defined; no translator clause or projector handler wired yet.
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
