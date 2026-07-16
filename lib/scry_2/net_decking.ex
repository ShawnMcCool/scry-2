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
  alias Scry2.Config
  alias Scry2.Decks.MtgaClipboardFormat
  alias Scry2.Economy
  alias Scry2.NetDecking.ArchetypeStamp
  alias Scry2.NetDecking.Buildability
  alias Scry2.NetDecking.Buildability.Inputs
  alias Scry2.NetDecking.Deck
  alias Scry2.NetDecking.DeckClusters
  alias Scry2.NetDecking.DeckQualities
  alias Scry2.NetDecking.IngestDecklist
  alias Scry2.NetDecking.OwnedIdentity
  alias Scry2.NetDecking.Provenance
  alias Scry2.NetDecking.VariantMatrix
  alias Scry2.NetDecking.Sources.{LocalJsonSource, MtgoSource}
  alias Scry2.Repo
  alias Scry2.Settings

  @empty_wildcards %{common: 0, uncommon: 0, rare: 0, mythic: 0}
  @cluster_signature_cards 4
  @default_sources [LocalJsonSource, MtgoSource]
  @auto_fetch_setting_prefix "netdecking.auto_fetch."

  # ── Sources ─────────────────────────────────────────────────────────

  @doc """
  The source roster — the single source of truth for which adapters exist.
  `config :scry_2, :netdecking_sources` is the override seam (used by tests).
  """
  @spec sources() :: [module()]
  def sources, do: Application.get_env(:scry_2, :netdecking_sources) || @default_sources

  @doc "Sources the import browser can offer: those declaring at least one format."
  @spec browsable_sources([module()]) :: [module()]
  def browsable_sources(source_modules \\ sources()) do
    Enum.filter(source_modules, fn source_module -> source_module.formats() != [] end)
  end

  @doc "Whether the scheduled fetch is enabled for a source. Defaults to enabled."
  @spec auto_fetch_enabled?(String.t()) :: boolean()
  def auto_fetch_enabled?(source_name) when is_binary(source_name) do
    enabled = Settings.get(@auto_fetch_setting_prefix <> source_name)
    if is_nil(enabled), do: true, else: enabled
  end

  @spec set_auto_fetch(String.t(), boolean()) :: :ok
  def set_auto_fetch(source_name, enabled?)
      when is_binary(source_name) and is_boolean(enabled?) do
    Settings.put!(@auto_fetch_setting_prefix <> source_name, enabled?)
    :ok
  end

  # ── Writes ──────────────────────────────────────────────────────────

  @spec import_decklist(map()) :: {:ok, Deck.t()} | {:error, Ecto.Changeset.t()}
  defdelegate import_decklist(attrs), to: IngestDecklist, as: :run

  @doc """
  Re-stamp every corpus deck's classified archetype against the current
  Metagame definitions. Returns the number of decks whose stamp changed.
  Classifications are disposable projections — safe to run any time.
  """
  @spec reclassify_archetypes!() :: non_neg_integer()
  def reclassify_archetypes! do
    list_decks()
    |> Enum.count(fn deck ->
      stamp = ArchetypeStamp.attrs(deck.main_deck, deck.sideboard, deck.format)
      changeset = Deck.changeset(deck, stamp)

      if changeset.changes == %{} do
        false
      else
        Repo.update!(changeset)
        true
      end
    end)
  end

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

  @doc "Distinct non-nil `source_url`s in the corpus — the browser's imported markers."
  @spec imported_source_urls() :: MapSet.t(String.t())
  def imported_source_urls do
    Deck
    |> where([deck], not is_nil(deck.source_url))
    |> select([deck], deck.source_url)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Scores all corpus decks against the current collection snapshot, clusters
  near-duplicate decks (read-time only — every deck row stays in the DB), and
  groups by buildability status:
  `%{buildable: [entry], craftable: [entry], short: [entry]}`, sorted
  cheapest-first.

  Each entry is the cluster representative decorated for display:
  `%{deck, result, color_identity, signature_arena_ids, label, set_code,
  variant_count, provenance}` — `provenance` is the cluster's best finish
  (`%{finish, event_name, event_date}`) or nil when no member carries
  competitive metadata (UIDR-010).
  """
  @spec catalog() :: %{buildable: [map()], craftable: [map()], short: [map()]}
  def catalog do
    decks = list_decks()
    snapshot = Collection.current()
    {raw_owned, wildcards} = collection_context(snapshot)

    cards_by_arena_id = cards_for(decks)
    owned = owned_by_identity(raw_owned, cards_by_arena_id)
    rarities = Map.new(cards_by_arena_id, fn {id, card} -> {id, card_rarity(card)} end)
    free_ids = Buildability.default_free_ids(cards_by_arena_id)
    sets = sets_by_id()

    scored =
      Map.new(decks, fn deck ->
        {deck.id, %{deck: deck, result: score_deck(deck, owned, wildcards, rarities, free_ids)}}
      end)

    items =
      Enum.map(decks, fn deck ->
        %{
          id: deck.id,
          set: nonland_signature(deck, cards_by_arena_id, free_ids),
          weight: total_wildcard_cost(scored[deck.id].result)
        }
      end)

    threshold = Config.get(:netdecking_cluster_threshold) || 0.7

    items
    |> DeckClusters.group(threshold)
    |> Enum.map(fn cluster ->
      %{deck: deck, result: result} = scored[cluster.representative_id]
      member_decks = Enum.map(cluster.member_ids, fn member_id -> scored[member_id].deck end)
      decorate(deck, result, member_decks, cards_by_arena_id, sets)
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

  Returns `%{deck, result, wildcards, main_rows, side_rows, export_text,
  label, variants, matrix, cards_by_arena_id}` where each row is
  `%{arena_id, name, rarity, needed, owned, missing, free?}`. `wildcards`
  are the player's current owned balances; `export_text` is the MTGA
  clipboard-import string; `label` is the archetype label (matches the
  catalog tile); `variants` lists every deck in this deck's cluster —
  `%{deck, finish, record, wildcard_cost, total_cost}`, best finish first
  (UIDR-010); `matrix` is the `VariantMatrix` view model over the same
  cluster in the same order (UIDR-014); `cards_by_arena_id` is the card
  reference lookup for rendering the deck composition.
  """
  @spec deck_detail(Deck.t()) :: map()
  def deck_detail(%Deck{} = deck) do
    decks = list_decks()
    snapshot = Collection.current()
    {raw_owned, wildcards} = collection_context(snapshot)

    # The whole corpus, not just this deck: clustering (variants) needs every
    # deck's nonland signature, and scoring the variants needs their cards.
    cards_by_arena_id = cards_for(decks)
    owned = owned_by_identity(raw_owned, cards_by_arena_id)

    rarities =
      Map.new(cards_by_arena_id, fn {arena_id, card} -> {arena_id, card_rarity(card)} end)

    free_ids = Buildability.default_free_ids(cards_by_arena_id)

    entries = card_entries(deck.main_deck)
    colors = DeckQualities.deck_color_identity(entries, cards_by_arena_id)

    signature =
      DeckQualities.signature_arena_ids(entries, cards_by_arena_id, @cluster_signature_cards)

    cluster_variants =
      variants(deck, decks, cards_by_arena_id, owned, wildcards, rarities, free_ids)

    %{
      deck: deck,
      result: score_deck(deck, owned, wildcards, rarities, free_ids),
      wildcards: wildcards,
      main_rows: card_rows(deck.main_deck, cards_by_arena_id, owned, rarities, free_ids),
      side_rows: card_rows(deck.sideboard, cards_by_arena_id, owned, rarities, free_ids),
      export_text:
        MtgaClipboardFormat.format_card_lists(deck.main_deck, deck.sideboard, cards_by_arena_id),
      label:
        cluster_label(
          Enum.map(cluster_variants, & &1.deck),
          colors,
          signature,
          cards_by_arena_id
        ),
      finish: Provenance.finish_label(deck),
      record: Provenance.record_label(deck),
      variants: cluster_variants,
      matrix:
        VariantMatrix.build(
          deck,
          Enum.map(cluster_variants, & &1.deck),
          cards_by_arena_id
        ),
      cards_by_arena_id: cards_by_arena_id
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp decorate(deck, result, member_decks, cards, sets) do
    entries = card_entries(deck.main_deck)
    colors = DeckQualities.deck_color_identity(entries, cards)
    signature = DeckQualities.signature_arena_ids(entries, cards, @cluster_signature_cards)

    %{
      deck: deck,
      result: result,
      color_identity: colors,
      signature_arena_ids: signature,
      label: cluster_label(member_decks, colors, signature, cards),
      set_code: DeckQualities.newest_set_code(entries, cards, sets),
      variant_count: length(member_decks),
      provenance: tile_provenance(member_decks)
    }
  end

  # The cluster title: the classified archetype name the community uses
  # ("Izzet Prowess"), by majority over the cluster's members. Falls back
  # to the synthetic color · hero label for unclassified decks. Never
  # derived from one variant's pilot/event — those mutate as the
  # representative changes with the collection (UIDR-010).
  defp cluster_label(member_decks, colors, signature, cards) do
    member_decks
    |> Enum.map(& &1.archetype_name)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_name, frequency} -> frequency end, fn -> nil end)
    |> case do
      {name, _frequency} -> name
      nil -> synthetic_label(colors, signature, cards)
    end
  end

  defp synthetic_label(colors, signature, cards) do
    hero_name = signature |> List.first() |> card_name_or(cards)
    "#{DeckQualities.color_combo_name(colors)} · #{hero_name}"
  end

  defp tile_provenance(member_decks) do
    case Provenance.best_finish_deck(member_decks) do
      nil ->
        nil

      best ->
        %{
          finish: Provenance.finish_label(best),
          event_name: best.event_name,
          event_date: best.event_date
        }
    end
  end

  # All decks in the same near-duplicate cluster as `deck` (itself included),
  # scored and ordered best finish first, wildcard cost as tie-break.
  defp variants(deck, decks, cards, owned, wildcards, rarities, free_ids) do
    threshold = Config.get(:netdecking_cluster_threshold) || 0.7

    items =
      Enum.map(decks, fn corpus_deck ->
        %{id: corpus_deck.id, set: nonland_signature(corpus_deck, cards, free_ids), weight: 0}
      end)

    member_ids =
      items
      |> DeckClusters.group(threshold)
      |> Enum.find_value([deck.id], fn cluster ->
        if deck.id in cluster.member_ids, do: cluster.member_ids
      end)

    decks_by_id = Map.new(decks, fn corpus_deck -> {corpus_deck.id, corpus_deck} end)

    member_ids
    |> Enum.map(&Map.get(decks_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn member_deck ->
      result = score_deck(member_deck, owned, wildcards, rarities, free_ids)

      %{
        deck: member_deck,
        finish: Provenance.finish_label(member_deck),
        record: Provenance.record_label(member_deck),
        wildcard_cost: result.maindeck.wildcard_cost,
        total_cost: total_wildcard_cost(result)
      }
    end)
    |> Enum.sort_by(fn variant ->
      {Provenance.finish_sort_key(variant.deck), variant.total_cost}
    end)
  end

  defp score_deck(deck, owned, wildcards, rarities, free_ids) do
    Buildability.score(%Inputs{
      main_cards: card_entries(deck.main_deck),
      side_cards: card_entries(deck.sideboard),
      owned: owned,
      wildcards: wildcards,
      rarities: rarities,
      free_arena_ids: free_ids
    })
  end

  defp card_name_or(nil, _cards), do: "Unknown"

  defp card_name_or(arena_id, cards) do
    case Map.get(cards, arena_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "#" <> Integer.to_string(arena_id)
    end
  end

  defp nonland_signature(deck, cards, free_ids) do
    deck.main_deck
    |> card_entries()
    |> Enum.map(& &1.arena_id)
    |> Enum.reject(fn id ->
      MapSet.member?(free_ids, id) or match?(%{is_land: true}, Map.get(cards, id))
    end)
    |> MapSet.new()
  end

  defp total_wildcard_cost(result) do
    result.maindeck.wildcard_cost |> Map.values() |> Enum.sum()
  end

  defp sets_by_id do
    Cards.list_sets()
    |> Map.new(fn set -> {set.id, %{code: set.code, released_at: set.released_at}} end)
  end

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

  defp collection_context(nil), do: {%{}, economy_wildcards()}

  defp collection_context(%Snapshot{} = snapshot) do
    owned = snapshot.cards_json |> Snapshot.decode_entries() |> Map.new()
    {owned, snapshot_wildcards(snapshot)}
  end

  # The memory walker stamps all four wildcard balances; the fallback scanner
  # stamps none. A balance-less snapshot means "the reader couldn't see
  # wildcards", not "zero wildcards" — the log-derived economy inventory is
  # then the best available source.
  defp snapshot_wildcards(%Snapshot{} = snapshot) do
    balances = [
      snapshot.wildcards_common,
      snapshot.wildcards_uncommon,
      snapshot.wildcards_rare,
      snapshot.wildcards_mythic
    ]

    if Enum.all?(balances, &is_nil/1) do
      economy_wildcards()
    else
      %{
        common: snapshot.wildcards_common || 0,
        uncommon: snapshot.wildcards_uncommon || 0,
        rare: snapshot.wildcards_rare || 0,
        mythic: snapshot.wildcards_mythic || 0
      }
    end
  end

  defp economy_wildcards do
    case Economy.latest_inventory() do
      nil ->
        @empty_wildcards

      inventory ->
        %{
          common: inventory.wildcards_common || 0,
          uncommon: inventory.wildcards_uncommon || 0,
          rare: inventory.wildcards_rare || 0,
          mythic: inventory.wildcards_mythic || 0
        }
    end
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
