defmodule Scry2.Buildability do
  @moduledoc """
  Scores any card list against the player's collection: how many copies
  of which cards are missing, what wildcards the rest would cost, and
  whether the list can be built or crafted today.

  Owns no tables — a read model over `Scry2.Collection` (owned copies,
  wildcard balances), `Scry2.Economy` (wildcard fallback) and
  `Scry2.Cards` (rarity, printings). Every deck surface in the app
  scores through this one path: the netdeck catalog, netdeck detail, and
  the player's own decks.

  ## Pipeline

  1. **Position** — `Scry2.Buildability.CollectionPosition.current/1`
     reads the collection once: owned copies rolled up across printings,
     wildcard balances, rarities, and the free (basic land) arena_ids.
  2. **Score** — `Scry2.Buildability.ScoreCardList` applies the pure
     rules: per-card shortage → rarity buckets → affordability → status
     and sort key, plus the per-card `CardRow`s.
  3. **Assess** — `assess/4` bundles both into an
     `Scry2.Buildability.Assessment`, the value the UI renders.

  Callers scoring many lists take the position once with `position/1` and
  call `score/4` per list — one collection read for the whole page.
  Callers scoring a single list call `assess/4`.

      iex> position = Buildability.position(cards_by_arena_id)
      iex> Buildability.score(position, deck.main_deck, deck.sideboard, 0)

  ## Unknown collection

  With no collection snapshot every card reads as missing. That is
  *unknown* ownership, not zero — `collection_known?` on the position and
  the assessment says so, and pages must suppress ownership annotation
  rather than claim the player owns nothing.
  """

  alias Scry2.Buildability.Assessment
  alias Scry2.Buildability.CollectionPosition
  alias Scry2.Buildability.Result
  alias Scry2.Buildability.ScoreCardList

  @doc """
  Reads the collection once and projects it onto `cards_by_arena_id` —
  the card reference for every card that will be scored.
  """
  @spec position(%{optional(integer()) => map()}) :: CollectionPosition.t()
  defdelegate position(cards_by_arena_id), to: CollectionPosition, as: :current

  @doc """
  Scores a maindeck/sideboard pair against a position.
  `unresolved_count` is the number of maindeck references that never
  resolved to an arena_id — see `ScoreCardList.score/4`.
  """
  @spec score(CollectionPosition.t(), term(), term(), non_neg_integer()) :: Result.t()
  defdelegate score(position, main_deck, sideboard, unresolved_count \\ 0), to: ScoreCardList

  @doc "Per-card ownership rows for one card list — see `ScoreCardList.card_rows/3`."
  defdelegate card_rows(position, card_list, cards_by_arena_id), to: ScoreCardList

  @doc "The default free-card policy (basic lands) — see `ScoreCardList.default_free_ids/1`."
  defdelegate default_free_ids(cards_by_arena_id), to: ScoreCardList

  @doc """
  Scores one card list end to end: reads the collection, scores the
  list, and builds the per-card rows.

  Options:
    * `:unresolved_count` — maindeck references that never resolved to an
      arena_id (default 0).
    * `:position` — a position already read this request, to avoid a
      second collection read.
  """
  @spec assess(term(), term(), %{optional(integer()) => map()}, keyword()) :: Assessment.t()
  def assess(main_deck, sideboard, cards_by_arena_id, opts \\ []) do
    position = Keyword.get_lazy(opts, :position, fn -> position(cards_by_arena_id) end)
    unresolved_count = Keyword.get(opts, :unresolved_count, 0)

    %Assessment{
      result: score(position, main_deck, sideboard, unresolved_count),
      main_rows: card_rows(position, main_deck, cards_by_arena_id),
      side_rows: card_rows(position, sideboard, cards_by_arena_id),
      wildcards: position.wildcards,
      collection_known?: position.collection_known?
    }
  end
end
