defmodule Scry2.NetDecking do
  @moduledoc """
  Public facade for the NetDecking context — a catalog of external reference
  decks scored against the user's collection.

  Owns: `netdecking_decks`. Consumes `Cards` (identity/rarity), `Collection`
  (owned counts + wildcards), and `Scry2.Decks.MtgaClipboardParser`/`...Format`
  (clipboard text) through their public APIs only.

  Buildability is computed at read time against the most recent collection
  snapshot (`catalog/0`). The corpus is small and the collection changes
  often, so no projection is stored (see the design spec).
  """
  import Ecto.Query

  alias Scry2.Cards
  alias Scry2.Collection
  alias Scry2.Collection.Snapshot
  alias Scry2.Decks.MtgaClipboardFormat
  alias Scry2.NetDecking.Buildability
  alias Scry2.NetDecking.Buildability.Inputs
  alias Scry2.NetDecking.Deck
  alias Scry2.NetDecking.IngestDecklist
  alias Scry2.NetDecking.OwnedIdentity
  alias Scry2.Repo

  @empty_wildcards %{common: 0, uncommon: 0, rare: 0, mythic: 0}

  # ── Writes ──────────────────────────────────────────────────────────

  @spec import_decklist(map()) :: {:ok, Deck.t()} | {:error, Ecto.Changeset.t()}
  defdelegate import_decklist(attrs), to: IngestDecklist, as: :run

  # ── Reads ───────────────────────────────────────────────────────────

  @spec list_decks() :: [Deck.t()]
  def list_decks, do: Deck |> order_by([deck], asc: deck.name) |> Repo.all()

  @doc """
  Per-source catalog status for the UI strip: `[%{source_name, count, latest}]`
  sorted by source name, where `latest` is the most recent `fetched_at` for
  that source.
  """
  @spec source_status() :: [
          %{source_name: String.t(), count: non_neg_integer(), latest: DateTime.t()}
        ]
  def source_status do
    list_decks()
    |> Enum.group_by(& &1.source_name)
    |> Enum.map(fn {source_name, decks} ->
      %{
        source_name: source_name,
        count: length(decks),
        latest: decks |> Enum.map(& &1.fetched_at) |> Enum.max(DateTime)
      }
    end)
    |> Enum.sort_by(& &1.source_name)
  end

  @spec get_deck(integer() | String.t()) :: Deck.t() | nil
  def get_deck(id), do: Repo.get(Deck, id)

  @doc """
  Scores all corpus decks against the current collection snapshot, grouped:
  `%{buildable: [entry], craftable: [entry], short: [entry]}` where each entry
  is `%{deck: Deck.t(), result: Buildability.Result.t()}`, sorted cheapest-first.
  """
  @spec catalog() :: %{buildable: [map()], craftable: [map()], short: [map()]}
  def catalog do
    decks = list_decks()
    snapshot = Collection.current()
    {raw_owned, wildcards} = collection_context(snapshot)

    cards_by_arena_id = cards_for(decks)
    owned = owned_by_identity(raw_owned, cards_by_arena_id)

    rarities =
      Map.new(cards_by_arena_id, fn {arena_id, card} -> {arena_id, card_rarity(card)} end)

    free_ids = Buildability.default_free_ids(cards_by_arena_id)

    decks
    |> Enum.map(fn deck ->
      inputs = %Inputs{
        main_cards: card_entries(deck.main_deck),
        side_cards: card_entries(deck.sideboard),
        owned: owned,
        wildcards: wildcards,
        rarities: rarities,
        free_arena_ids: free_ids
      }

      %{deck: deck, result: Buildability.score(inputs)}
    end)
    |> Enum.sort_by(& &1.result.sort_key)
    |> Enum.group_by(& &1.result.status)
    |> then(fn grouped ->
      %{
        buildable: Map.get(grouped, :buildable, []),
        craftable: Map.get(grouped, :craftable, []),
        short: Map.get(grouped, :short, [])
      }
    end)
  end

  @doc """
  Detailed view model for a single deck, scored against the current snapshot.

  Returns `%{deck, result, wildcards, main_rows, side_rows, export_text}` where
  each row is `%{arena_id, name, rarity, needed, owned, missing, free?}`.
  `wildcards` are the player's current owned balances; `export_text` is the
  MTGA clipboard-import string.
  """
  @spec deck_detail(Deck.t()) :: map()
  def deck_detail(%Deck{} = deck) do
    snapshot = Collection.current()
    {raw_owned, wildcards} = collection_context(snapshot)

    cards_by_arena_id = cards_for([deck])
    owned = owned_by_identity(raw_owned, cards_by_arena_id)

    rarities =
      Map.new(cards_by_arena_id, fn {arena_id, card} -> {arena_id, card_rarity(card)} end)

    free_ids = Buildability.default_free_ids(cards_by_arena_id)

    inputs = %Inputs{
      main_cards: card_entries(deck.main_deck),
      side_cards: card_entries(deck.sideboard),
      owned: owned,
      wildcards: wildcards,
      rarities: rarities,
      free_arena_ids: free_ids
    }

    %{
      deck: deck,
      result: Buildability.score(inputs),
      wildcards: wildcards,
      main_rows: card_rows(deck.main_deck, cards_by_arena_id, owned, rarities, free_ids),
      side_rows: card_rows(deck.sideboard, cards_by_arena_id, owned, rarities, free_ids),
      export_text:
        MtgaClipboardFormat.format_card_lists(deck.main_deck, deck.sideboard, cards_by_arena_id)
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp card_rows(card_list, cards_by_arena_id, owned, rarities, free_ids) do
    card_list
    |> card_entries()
    |> Enum.map(fn %{arena_id: arena_id, count: needed} ->
      free? = MapSet.member?(free_ids, arena_id)
      owned_count = Map.get(owned, arena_id, 0)
      missing = if free?, do: 0, else: max(0, needed - owned_count)

      %{
        arena_id: arena_id,
        name: card_name(cards_by_arena_id, arena_id),
        rarity: Map.get(rarities, arena_id),
        needed: needed,
        owned: owned_count,
        missing: missing,
        free?: free?
      }
    end)
  end

  defp card_name(cards_by_arena_id, arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      %{name: name} when is_binary(name) -> name
      _other -> "#" <> Integer.to_string(arena_id)
    end
  end

  # Aggregates raw arena_id-keyed ownership across printings onto each deck
  # card's representative arena_id (card-name identity). Collector-less web
  # sources resolve to one printing; the player may own another. See
  # `Scry2.NetDecking.OwnedIdentity`.
  defp owned_by_identity(raw_owned, cards_by_arena_id) do
    names = cards_by_arena_id |> Map.values() |> Enum.map(& &1.name) |> Enum.uniq()
    printings = Cards.printings_by_name(names)
    OwnedIdentity.owned_by_representative(cards_by_arena_id, raw_owned, printings)
  end

  defp collection_context(nil), do: {%{}, @empty_wildcards}

  defp collection_context(%Snapshot{} = snapshot) do
    owned = snapshot.cards_json |> Snapshot.decode_entries() |> Map.new()

    wildcards = %{
      common: snapshot.wildcards_common || 0,
      uncommon: snapshot.wildcards_uncommon || 0,
      rare: snapshot.wildcards_rare || 0,
      mythic: snapshot.wildcards_mythic || 0
    }

    {owned, wildcards}
  end

  defp cards_for(decks) do
    decks
    |> Enum.flat_map(fn deck -> card_entries(deck.main_deck) ++ card_entries(deck.sideboard) end)
    |> Enum.map(& &1.arena_id)
    |> Enum.uniq()
    |> Cards.list_by_arena_ids()
  end

  defp card_entries(%{"cards" => cards}) when is_list(cards) do
    Enum.map(cards, fn card ->
      %{arena_id: card["arena_id"] || card[:arena_id], count: card["count"] || card[:count]}
    end)
  end

  defp card_entries(_), do: []

  defp card_rarity(%{rarity: rarity}) when is_binary(rarity), do: rarity
  defp card_rarity(_), do: nil
end
