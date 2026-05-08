defmodule Scry2.Cards.Synthesize.Pairing do
  @moduledoc """
  Decides which Scryfall row joins which MTGA card during synthesis.

  Joins by `(upcase(set_code), collector_number)` — the universal MTG
  printing identifier present in both sources (verified: 0 missing in
  ~114k Scryfall rows, 4 missing in ~25k MTGA rows). `arena_id` is NOT
  used here: it's MTGA's internal row identity, retained on `cards_cards`
  for event-side joins (ADR-014), but unsuitable as a join key between
  reference sources because Scryfall lags weeks/months in populating
  `arena_id` for new sets. See ADR-038.

  ## Tokens

  Returns `nil` for any MTGA card with `is_token=true`. Two reasons:

    * MTGA emits tokens under the parent set's code (e.g. SOS#1 is both
      *The Dawning Archaic* AND a *Copy* token).
    * Scryfall keeps tokens under prefixed token-set codes (`TSOS`,
      `TLCI`, etc.), not the parent set. So a token's `(SOS, 1)` would
      either miss entirely OR silently match the parent card and enrich
      the token with the wrong row's data.

  Tokens get MTGA-only synthesis. They're already excluded from the
  user-facing search/list paths (`Cards.list_cards` filters
  `rarity != "token"`).

  ## Defensive case normalisation

  Scryfall stores set codes uppercase via `Cards.upsert_scryfall_card!`,
  but MTGA's `expansion_code` is stored as imported. Both sides upper
  here so a casing mismatch upstream doesn't silently break the join.
  """

  alias Scry2.Cards.{MtgaCard, ScryfallCard}

  @type set_number_index :: %{{String.t(), String.t()} => ScryfallCard.t()}

  @doc """
  Returns the Scryfall row whose `(upcase(set_code), collector_number)`
  matches the MTGA card, or `nil` when no match exists or the card is
  ineligible (token, missing collector_number).
  """
  @spec for_mtga(MtgaCard.t(), set_number_index()) :: ScryfallCard.t() | nil
  def for_mtga(%MtgaCard{is_token: true}, _index), do: nil

  def for_mtga(%MtgaCard{expansion_code: code, collector_number: num}, index)
      when is_binary(code) and code != "" and is_binary(num) and num != "" do
    Map.get(index, {String.upcase(code), num})
  end

  def for_mtga(_mtga, _index), do: nil
end
