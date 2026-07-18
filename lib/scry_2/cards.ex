defmodule Scry2.Cards do
  @moduledoc """
  Context module for card reference data.

  Owns tables: `cards_cards`, `cards_sets`, `cards_scryfall_cards`,
  `cards_mtga_cards`.

  PubSub role: broadcasts `"cards:updates"` after reference-data refreshes.

  ## Source-of-truth pipeline

  Card data flows through three independent importers and one synthesis
  step:

  1. `Scry2.Cards.MtgaClientData` — reads the MTGA client's
     `Raw_CardDatabase_*.mtga` SQLite into `cards_mtga_cards`.
     Canonical Arena card list. Zero third-party dependency.
  2. `Scry2.Cards.Scryfall` — streams Scryfall bulk data into
     `cards_scryfall_cards`. Provides oracle metadata + image URIs.
  3. `Scry2.Cards.Synthesize` — joins the two sources by `arena_id` and
     upserts `cards_cards`. Disposable read model.

  See ADR-014 for the `arena_id` identity invariant.

  ## Cross-context consumption

  Other contexts read card reference data freely. The intentionally-public
  surface of `Scry2.Cards` is:

    * **Functions on this module** (`get_card_by_arena_id/1`,
      `lookup_booster_collation/1`, `list_sets/0`, …) — preferred for
      lookups and computations.
    * **Struct types** `%Scry2.Cards.Card{}`, `%Scry2.Cards.Set{}`, and
      `%Scry2.Cards.SetRoster{}` — exposed as value types because the
      collection consumers (`Scry2.Collection.Holding`,
      `Scry2.Collection.Completion`) operate on them in `@type` specs and
      pattern matches. These shapes are part of the contract.

  Anything else under `lib/scry_2/cards/` is internal — do not alias from
  outside the context.
  """

  import Ecto.Query

  alias Scry2.Cards.{BoosterCollation, Card, MtgaCard, ScryfallCard, Set}
  alias Scry2.Repo
  alias Scry2.Settings

  @synthesis_refresh_key "cards_synthesized_last_refresh_at"
  @scryfall_refresh_key "cards_scryfall_last_refresh_at"
  @mtga_client_refresh_key "cards_mtga_client_last_refresh_at"

  # ── Booster collation ───────────────────────────────────────────────────

  @doc """
  Resolves a MTGA `collationId` to a set code via the cached booster
  collation index, or `nil` if the id has no recorded mapping.

  Public-API surface for `Scry2.Collection.PendingPacks` and any other
  consumer that needs to label boosters by set without reaching into
  the cache module's internal state.
  """
  @spec lookup_booster_collation(integer()) :: String.t() | nil
  def lookup_booster_collation(collation_id) when is_integer(collation_id) do
    BoosterCollation.lookup(collation_id)
  end

  # ── Sets ────────────────────────────────────────────────────────────────

  @doc "Returns the set with the given `code`, or nil."
  def get_set_by_code(code) when is_binary(code) do
    Repo.get_by(Set, code: code)
  end

  @doc """
  Lists every known set, newest-first by `released_at`. Sets without a
  `released_at` are returned after dated ones, sorted by `code`.
  """
  @spec list_sets() :: [Set.t()]
  def list_sets do
    Set
    |> order_by([s],
      asc: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", s.released_at),
      desc: s.released_at,
      asc: s.code
    )
    |> Repo.all()
  end

  @doc """
  Upserts a set by its `code`. Returns the persisted record.
  """
  def upsert_set!(%{code: code} = attrs) when is_binary(code) do
    case get_set_by_code(code) do
      nil ->
        %Set{}
        |> Set.changeset(attrs)
        |> Repo.insert!()

      existing ->
        existing
        |> Set.changeset(attrs)
        |> Repo.update!()
    end
  end

  # ── Cards ───────────────────────────────────────────────────────────────

  @doc "Returns the total card count."
  def count do
    Repo.aggregate(Card, :count)
  end

  @doc """
  Lists cards with optional filters. Results are deduplicated by name —
  one row per unique card name (the earliest-imported representative is kept).
  When `:name_like` is set, results are ordered by match quality: exact match
  first, starts-with second, contains-anywhere third, then alphabetically
  within each tier.

  Supported filters:
    * `:set_code`    — filter by set code
    * `:rarity`      — rarity string or list of rarity strings
    * `:name_like`   — substring match on name
    * `:colors`      — `MapSet` of color codes (`"W"`, `"U"`, `"B"`, `"R"`, `"G"`, `"M"`, `"C"`);
                       OR semantics. `"M"` = multicolor. `"C"` = colorless.
    * `:types`       — `MapSet` of type atoms (`:creature`, `:instant`, `:sorcery`,
                       `:enchantment`, `:artifact`, `:planeswalker`, `:land`, `:battle`);
                       OR semantics within, AND with other filters.
    * `:mana_values` — `MapSet` of integers (0–6) and/or `:seven_plus`
    * `:limit`       — cap result count (default 100)
  """
  def list_cards(filters \\ %{}) do
    filters = Map.new(filters)
    term = filters[:name_like]

    Card
    |> exclude_tokens()
    |> filter_by_set(filters[:set_code])
    |> filter_by_rarity(filters[:rarity])
    |> filter_by_name(term)
    |> filter_by_colors(filters[:colors])
    |> filter_by_types(filters[:types])
    |> filter_by_mana_values(filters[:mana_values])
    |> deduplicate_by_name()
    |> order_by_relevance(term)
    |> limit(^Map.get(filters, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Counts unique card names matching filters (same keys as `list_cards/1`, ignores `:limit`).
  """
  def count_cards(filters \\ %{}) do
    filters = Map.new(filters) |> Map.drop([:limit, :order_by])

    Card
    |> exclude_tokens()
    |> filter_by_set(filters[:set_code])
    |> filter_by_rarity(filters[:rarity])
    |> filter_by_name(filters[:name_like])
    |> filter_by_colors(filters[:colors])
    |> filter_by_types(filters[:types])
    |> filter_by_mana_values(filters[:mana_values])
    |> deduplicate_by_name()
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns storage stats for card data sources.

  Keys: `:synthesized_count`, `:synthesized_bytes`, `:scryfall_count`,
        `:scryfall_bytes`, `:mtga_client_count`, `:mtga_client_bytes`,
        `:db_bytes`, `:image_count`, `:image_bytes`.
  """
  def data_source_stats do
    image_cache_dir = Scry2.Config.get(:image_cache_dir)
    {image_count, image_bytes} = image_cache_stats(image_cache_dir)

    %{
      synthesized_count: Repo.aggregate(Card, :count),
      synthesized_bytes: table_size_bytes("cards_cards"),
      scryfall_count: Repo.aggregate(ScryfallCard, :count),
      scryfall_bytes: table_size_bytes("cards_scryfall_cards"),
      mtga_client_count: Repo.aggregate(MtgaCard, :count),
      mtga_client_bytes: table_size_bytes("cards_mtga_cards"),
      db_bytes: db_file_size(),
      image_count: image_count,
      image_bytes: image_bytes
    }
  end

  @doc """
  Returns the last **successful refresh** timestamp for each card data
  source.

  Keys in the returned map: `:synthesized_updated_at`, `:scryfall_updated_at`,
  `:mtga_client_updated_at` (all may be nil).
  """
  def import_timestamps do
    %{
      synthesized_updated_at: read_refresh_timestamp(@synthesis_refresh_key),
      scryfall_updated_at: read_refresh_timestamp(@scryfall_refresh_key),
      mtga_client_updated_at: read_refresh_timestamp(@mtga_client_refresh_key)
    }
  end

  @doc """
  Records a successful synthesis run at the current UTC time.
  """
  @spec record_synthesis_refresh!(DateTime.t()) :: :ok
  def record_synthesis_refresh!(now \\ DateTime.utc_now()) do
    Settings.put!(@synthesis_refresh_key, DateTime.to_iso8601(now))
    :ok
  end

  @doc """
  Records a successful Scryfall import at the current UTC time.
  """
  @spec record_scryfall_refresh!(DateTime.t()) :: :ok
  def record_scryfall_refresh!(now \\ DateTime.utc_now()) do
    Settings.put!(@scryfall_refresh_key, DateTime.to_iso8601(now))
    :ok
  end

  @doc """
  Records a successful MTGA client database import at the current UTC time.
  """
  @spec record_mtga_client_refresh!(DateTime.t()) :: :ok
  def record_mtga_client_refresh!(now \\ DateTime.utc_now()) do
    Settings.put!(@mtga_client_refresh_key, DateTime.to_iso8601(now))
    :ok
  end

  @doc "Returns the count of MTGA client cards currently in the database."
  @spec mtga_client_count() :: non_neg_integer()
  def mtga_client_count, do: Repo.aggregate(MtgaCard, :count)

  defp read_refresh_timestamp(key) do
    case Settings.get(key) do
      nil ->
        nil

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp image_cache_stats(nil), do: {0, 0}

  defp image_cache_stats(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        {count, total_bytes} =
          Enum.reduce(files, {0, 0}, fn file, {count, bytes} ->
            path = Path.join(dir, file)

            case File.stat(path) do
              {:ok, %File.Stat{type: :regular, size: size}} -> {count + 1, bytes + size}
              _ -> {count, bytes}
            end
          end)

        {count, total_bytes}

      {:error, _} ->
        {0, 0}
    end
  end

  defp table_size_bytes(table_name) do
    result =
      Repo.query!("SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name = ?", [table_name])

    result.rows |> List.first() |> List.first() |> Kernel.||(0)
  end

  defp db_file_size do
    db_path = Scry2.Config.get(:database_path)

    case db_path && File.stat(db_path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp exclude_tokens(query), do: where(query, [c], c.rarity != "token")

  defp filter_by_set(query, nil), do: query

  defp filter_by_set(query, code) when is_binary(code) do
    from c in query,
      join: s in assoc(c, :set),
      where: s.code == ^code
  end

  defp filter_by_rarity(query, nil), do: query
  defp filter_by_rarity(query, []), do: query

  defp filter_by_rarity(query, rarities) when is_list(rarities) do
    where(query, [c], c.rarity in ^rarities)
  end

  defp filter_by_rarity(query, rarity) when is_binary(rarity) do
    where(query, [c], c.rarity == ^rarity)
  end

  defp filter_by_name(query, nil), do: query
  defp filter_by_name(query, ""), do: query

  defp filter_by_name(query, term) when is_binary(term) do
    pattern = "%#{term}%"
    where(query, [c], like(c.name, ^pattern))
  end

  # Colors: OR semantics. "M" = multicolor, "C" = colorless, others match color_identity substring.
  defp filter_by_colors(query, nil), do: query
  defp filter_by_colors(query, %MapSet{map: m}) when map_size(m) == 0, do: query

  defp filter_by_colors(query, colors) do
    dynamic_clause =
      Enum.reduce(MapSet.to_list(colors), false, fn color, acc ->
        dynamic([c], ^acc or ^color_condition(color))
      end)

    where(query, [c], ^dynamic_clause)
  end

  defp color_condition("C"), do: dynamic([c], c.color_identity == "")
  defp color_condition("M"), do: dynamic([c], fragment("length(?)", c.color_identity) > 1)

  defp color_condition(color) when color in ["W", "U", "B", "R", "G"] do
    pattern = "%#{color}%"
    dynamic([c], like(c.color_identity, ^pattern))
  end

  # Types: OR within, AND with all other filters. Uses indexed boolean columns.
  defp filter_by_types(query, nil), do: query
  defp filter_by_types(query, %MapSet{map: m}) when map_size(m) == 0, do: query

  defp filter_by_types(query, types) do
    dynamic_clause =
      Enum.reduce(MapSet.to_list(types), false, fn type_atom, acc ->
        dynamic([c], ^acc or ^type_condition(type_atom))
      end)

    where(query, [c], ^dynamic_clause)
  end

  defp type_condition(:creature), do: dynamic([c], c.is_creature == true)
  defp type_condition(:instant), do: dynamic([c], c.is_instant == true)
  defp type_condition(:sorcery), do: dynamic([c], c.is_sorcery == true)
  defp type_condition(:enchantment), do: dynamic([c], c.is_enchantment == true)
  defp type_condition(:artifact), do: dynamic([c], c.is_artifact == true)
  defp type_condition(:planeswalker), do: dynamic([c], c.is_planeswalker == true)
  defp type_condition(:land), do: dynamic([c], c.is_land == true)
  defp type_condition(:battle), do: dynamic([c], c.is_battle == true)

  # Mana values: OR semantics. :seven_plus matches mana_value >= 7.
  defp filter_by_mana_values(query, nil), do: query
  defp filter_by_mana_values(query, %MapSet{map: m}) when map_size(m) == 0, do: query

  defp filter_by_mana_values(query, values) do
    value_list = MapSet.to_list(values)
    exact_values = Enum.filter(value_list, &is_integer/1)
    include_seven_plus = :seven_plus in value_list

    cond do
      exact_values != [] and include_seven_plus ->
        where(query, [c], c.mana_value in ^exact_values or c.mana_value >= 7)

      exact_values != [] ->
        where(query, [c], c.mana_value in ^exact_values)

      include_seven_plus ->
        where(query, [c], c.mana_value >= 7)

      true ->
        query
    end
  end

  # Returns one row per unique card name, keeping the earliest-imported (MIN id)
  # representative from the already-filtered set.
  defp deduplicate_by_name(query) do
    # Priority when multiple printings share a name:
    #   1. Most recent regular booster card with arena_id (booster=true = standard art, not showcase/borderless)
    #   2. Most recent any card with arena_id (special art treatments still playable on Arena)
    #   3. Most recent overall (no Arena version exists)
    ids_query =
      from q in subquery(query),
        left_join: mc in "cards_mtga_cards",
        on: mc.arena_id == q.arena_id,
        left_join: sc in "cards_scryfall_cards",
        on:
          sc.set_code == mc.expansion_code and
            sc.collector_number == mc.collector_number,
        group_by: q.name,
        select:
          fragment(
            "COALESCE(MAX(CASE WHEN ? IS NOT NULL AND ? = 1 THEN ? END), MAX(CASE WHEN ? IS NOT NULL THEN ? END), MAX(?))",
            q.arena_id,
            sc.booster,
            q.id,
            q.arena_id,
            q.id,
            q.id
          )

    where(query, [c], c.id in subquery(ids_query))
  end

  # When a name search is active: exact match (0) → starts-with (1) → contains (2),
  # then alphabetical within each tier. Falls back to alphabetical with no term.
  defp order_by_relevance(query, nil) do
    order_by(query, [c], asc: c.name)
  end

  defp order_by_relevance(query, term) do
    order_by(query, [c], [
      fragment(
        "CASE WHEN lower(?) = lower(?) THEN 0 WHEN lower(?) LIKE lower(?) || '%' THEN 1 ELSE 2 END",
        c.name,
        ^term,
        c.name,
        ^term
      ),
      asc: c.name
    ])
  end

  @doc "Returns the card for the given MTGA arena_id, or nil."
  def get_by_arena_id(arena_id) when is_integer(arena_id) do
    Repo.get_by(Card, arena_id: arena_id)
  end

  @doc """
  Returns the canonical display image URL for an arena_id, or nil.

  Reads the `image_url` that `Synthesize` stamps onto `cards_cards` —
  the most basic printing of the card's name (`Scry2.Cards.BasicPrinting`).
  Nil for unstamped rows; `ImageCache` then falls back to the live
  Scryfall API by `(set, collector_number)`.
  """
  def get_image_url_for_arena_id(arena_id) when is_integer(arena_id) do
    display_art_column(arena_id, :image_url)
  end

  @doc "Returns the canonical display `art_crop` (illustration-only) URL for an arena_id, or nil."
  def get_art_url_for_arena_id(arena_id) when is_integer(arena_id) do
    display_art_column(arena_id, :art_crop_url)
  end

  defp display_art_column(arena_id, column) do
    Repo.one(
      from card in Card,
        where: card.arena_id == ^arena_id,
        select: field(card, ^column)
    )
  end

  @doc """
  Whether synthesis has stamped canonical display art onto the read
  model yet. False on databases that predate the art-complete schema —
  `Cards.Bootstrap` re-synthesises and `ImageCache` defers its cache
  turnover until this flips true.
  """
  @spec display_art_stamped?() :: boolean()
  def display_art_stamped? do
    Repo.exists?(from card in Card, where: not is_nil(card.image_url))
  end

  @doc """
  Returns a map of arena_id => card data for a list of arena_ids.

  Queries `cards_cards` (synthesised) first for rich data (human-readable types,
  mana_value, color_identity). For any arena_ids not found there, falls back
  to `cards_mtga_cards` — the primary card identity source that covers every
  MTGA arena_id. MtgaCard fallback entries have `mana_value: 0` and
  `color_identity: ""` with types decoded from MTGA integer enums.
  """
  def list_by_arena_ids(arena_ids) when is_list(arena_ids) do
    arena_ids = Enum.filter(arena_ids, &is_integer/1)

    from_cards =
      Card
      |> where([c], c.arena_id in ^arena_ids)
      |> preload(:set)
      |> Repo.all()
      |> Map.new(&{&1.arena_id, &1})

    missing_ids = Enum.reject(arena_ids, &Map.has_key?(from_cards, &1))

    from_mtga =
      if missing_ids == [] do
        %{}
      else
        MtgaCard
        |> where([c], c.arena_id in ^missing_ids)
        |> Repo.all()
        |> Map.new(fn c ->
          {c.arena_id,
           %{
             arena_id: c.arena_id,
             name: c.name,
             types: decode_mtga_types(c.types),
             mana_value: c.mana_value,
             color_identity: ""
           }}
        end)
      end

    Map.merge(from_mtga, from_cards)
  end

  # Rarities counted toward set completion. Mirrors `Scry2.Cards.SetRoster`
  # so per-set tile totals and per-set detail card lists agree by definition.
  @booster_rarities ~w(common uncommon rare mythic)

  @doc """
  Returns the booster-legal cards for one set as a list of `%Card{}`.

  Mirrors `Scry2.Cards.SetRoster.compute/0`'s filter so the set-detail
  view's missing/partial/complete buckets always tally to the same
  per-rarity totals the overview tiles report:

    * Rarity must be one of `common | uncommon | rare | mythic` (basics
      and tokens excluded by definition).
    * Either `is_booster = true`, OR the set has zero rows tagged
      `is_booster = true` at all (Scryfall lag fallback — same shape as
      the case fixed in ADR-038).
  """
  @spec list_booster_cards_by_set(integer()) :: [Card.t()]
  def list_booster_cards_by_set(set_id) when is_integer(set_id) do
    has_booster_signal? =
      Card
      |> where([c], c.set_id == ^set_id and c.is_booster == true)
      |> Repo.exists?()

    base =
      Card
      |> where([c], c.set_id == ^set_id)
      |> where([c], c.rarity in @booster_rarities)

    base
    |> maybe_require_booster(has_booster_signal?)
    |> Repo.all()
  end

  defp maybe_require_booster(query, true), do: where(query, [c], c.is_booster == true)
  defp maybe_require_booster(query, false), do: query

  @doc """
  Returns the subset of `arena_ids` that correspond to token cards in
  `cards_mtga_cards`. Tokens are not deck cards — MTGA emits draw
  annotations for them during play, but they have no meaningful per-card
  metrics. Consumers (deck analytics) use this to filter token rows out.
  """
  @spec token_arena_ids([integer()]) :: MapSet.t(integer())
  def token_arena_ids(arena_ids) when is_list(arena_ids) do
    MtgaCard
    |> where([c], c.arena_id in ^arena_ids and c.is_token)
    |> select([c], c.arena_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a map of `arena_id => card_name` for the given arena_ids.
  Resolves from both `cards_cards` (synthesised) and `cards_mtga_cards`.
  """
  def names_by_arena_ids(arena_ids) when is_list(arena_ids) do
    list_by_arena_ids(arena_ids)
    |> Map.new(fn {arena_id, card} ->
      name = if is_map(card), do: Map.get(card, :name) || card[:name], else: nil
      {arena_id, name}
    end)
  end

  @doc """
  Maps each given card name (case-insensitive) to all `arena_id`s that share it.

  Returns `%{downcased_name => [arena_id]}`; names with no matching card are
  omitted. Single batch query — never N+1. Used to aggregate collection
  ownership across printings: a card owned under any printing's `arena_id`
  counts toward any deck listing that card by name (see
  `Scry2.NetDecking.OwnedIdentity`).
  """
  @spec printings_by_name([String.t()]) :: %{String.t() => [integer()]}
  def printings_by_name(names) when is_list(names) do
    downcased = names |> Enum.map(&String.downcase/1) |> Enum.uniq()

    Card
    |> where([c], fragment("lower(?)", c.name) in ^downcased)
    |> select([c], {fragment("lower(?)", c.name), c.arena_id})
    |> Repo.all()
    |> Enum.group_by(fn {name, _id} -> name end, fn {_name, id} -> id end)
  end

  @doc """
  Maps each given `arena_id` onto a stable representative `arena_id` for its card
  name — the lowest printing `arena_id` across every printing that shares the
  name. Arena_ids with no card row map to themselves.

  This collapses printing-only differences (card styles, alternate art, re-imports)
  so a decklist has one identity regardless of which printing MTGA recorded. See
  `Scry2.Decks.CompositionIdentity`.
  """
  @spec representative_arena_ids([integer()]) :: %{optional(integer()) => integer()}
  def representative_arena_ids([]), do: %{}

  def representative_arena_ids(arena_ids) when is_list(arena_ids) do
    id_to_name =
      Card
      |> where([c], c.arena_id in ^arena_ids)
      |> select([c], {c.arena_id, fragment("lower(?)", c.name)})
      |> Repo.all()
      |> Map.new()

    representative_by_name =
      id_to_name
      |> Map.values()
      |> Enum.uniq()
      |> printings_by_name()
      |> Map.new(fn {name, printing_ids} -> {name, Enum.min(printing_ids)} end)

    Map.new(arena_ids, fn arena_id ->
      representative =
        case Map.get(id_to_name, arena_id) do
          nil -> arena_id
          name -> Map.get(representative_by_name, name, arena_id)
        end

      {arena_id, representative}
    end)
  end

  @doc """
  Resolves parsed card references to `%{arena_id, count}` entries.

  Each ref is `%{name, set_code, collector_number, count}`. Matches on
  `(set_code, collector_number)` first, then case-insensitive name. Returns
  `%{resolved: [%{arena_id, count}], unresolved: [ref]}`. Never drops a ref.

  Uses two batch queries — never N+1:
  1. By lowercased name (handles name-only refs and provides a fallback for
     refs that also carry set/collector data).
  2. By `(set_code, collector_number)` pairs (only when at least one ref
     supplies both; wins over the name match).
  """
  @spec resolve_references([map()]) :: %{resolved: [map()], unresolved: [map()]}
  def resolve_references(refs) when is_list(refs) do
    names =
      refs
      |> Enum.flat_map(fn ref -> [ref.name, front_face(ref.name)] end)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    set_collector_refs =
      Enum.reject(refs, &(is_nil(&1.set_code) or is_nil(&1.collector_number)))

    set_codes =
      set_collector_refs |> Enum.map(fn r -> String.upcase(r.set_code) end) |> Enum.uniq()

    collector_numbers = set_collector_refs |> Enum.map(& &1.collector_number) |> Enum.uniq()

    by_name_candidates =
      Card
      |> where([c], fragment("lower(?)", c.name) in ^names)
      |> Repo.all()

    by_set_collector_candidates =
      if set_codes == [] do
        []
      else
        Card
        |> join(:inner, [c], s in assoc(c, :set))
        |> where(
          [c, s],
          fragment("upper(?)", s.code) in ^set_codes and
            c.collector_number in ^collector_numbers
        )
        |> preload([c, s], set: s)
        |> Repo.all()
      end

    by_set_collector =
      Map.new(by_set_collector_candidates, fn card ->
        {{reference_set_code(card), card.collector_number}, card}
      end)

    by_name =
      Enum.reduce(by_name_candidates, %{}, fn card, acc ->
        Map.put_new(acc, String.downcase(card.name), card)
      end)

    {resolved, unresolved} =
      Enum.reduce(refs, {[], []}, fn ref, {res, unres} ->
        case match_card_ref(ref, by_set_collector, by_name) do
          nil -> {res, [ref | unres]}
          card -> {[%{arena_id: card.arena_id, count: ref.count} | res], unres}
        end
      end)

    %{resolved: Enum.reverse(resolved), unresolved: Enum.reverse(unresolved)}
  end

  defp match_card_ref(ref, by_set_collector, by_name) do
    set_code = ref.set_code && String.upcase(ref.set_code)
    collector_number = ref.collector_number
    key = {set_code, collector_number}

    cond do
      set_code && collector_number && Map.has_key?(by_set_collector, key) ->
        Map.get(by_set_collector, key)

      Map.has_key?(by_name, String.downcase(ref.name)) ->
        Map.get(by_name, String.downcase(ref.name))

      true ->
        # Double-faced source names ("Front // Back") fall back to the front
        # face; full-name match above wins, so true split cards stored with
        # "//" still resolve to their own row.
        Map.get(by_name, String.downcase(front_face(ref.name)))
    end
  end

  # Front face of a double-faced/split name; the whole string if no " // ".
  defp front_face(name) do
    case String.split(name, " // ", parts: 2) do
      [front, _back] -> front
      _ -> name
    end
  end

  defp reference_set_code(%Card{set: %{code: code}}) when is_binary(code), do: String.upcase(code)
  defp reference_set_code(_), do: nil

  # Decodes MTGA's comma-separated integer type enums to a space-separated
  # human-readable string (e.g. "2,5" → "Creature Land"). Used only for
  # MtgaCard fallback entries where synthesised data is unavailable.
  #
  # MTGA type enum values (from Raw_CardDatabase Cards.Types column):
  #   1=Artifact, 2=Creature, 3=Enchantment, 4=Instant, 5=Land,
  #   8=Planeswalker, 10=Sorcery
  defp decode_mtga_types(nil), do: ""

  defp decode_mtga_types(types_str) do
    types_str
    |> String.split(",", trim: true)
    |> Enum.map(&mtga_type_name/1)
    |> Enum.join(" ")
  end

  defp mtga_type_name("1"), do: "Artifact"
  defp mtga_type_name("2"), do: "Creature"
  defp mtga_type_name("3"), do: "Enchantment"
  defp mtga_type_name("4"), do: "Instant"
  defp mtga_type_name("5"), do: "Land"
  defp mtga_type_name("8"), do: "Planeswalker"
  defp mtga_type_name("10"), do: "Sorcery"
  defp mtga_type_name(other), do: other

  @doc """
  Upserts a card from the synthesis pipeline by `arena_id`. Returns the
  persisted record.
  """
  def synthesize_card!(attrs) do
    attrs = Map.new(attrs)

    %Card{}
    |> Card.synthesis_changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:arena_id]
    )
  end

  # ── Scryfall Cards ────────────────────────────────────────────────────────

  @doc "Returns the total Scryfall card count."
  def scryfall_count do
    Repo.aggregate(ScryfallCard, :count)
  end

  @doc "Returns the Scryfall card for the given MTGA arena_id, or nil."
  def get_scryfall_by_arena_id(arena_id) when is_integer(arena_id) do
    Repo.get_by(ScryfallCard, arena_id: arena_id)
  end

  # ── MTGA Cards ─────────────────────────────────────────────────────────

  @doc "Returns the total MTGA card count."
  def mtga_card_count do
    Repo.aggregate(MtgaCard, :count)
  end

  @doc "Returns the MTGA card for the given arena_id, or nil."
  def get_mtga_card(arena_id) when is_integer(arena_id) do
    Repo.get_by(MtgaCard, arena_id: arena_id)
  end

  @doc "Upserts an MTGA card by `arena_id`."
  def upsert_mtga_card!(attrs) do
    attrs = Map.new(attrs)

    %MtgaCard{}
    |> MtgaCard.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:arena_id]
    )
  end

  @doc """
  Upserts a Scryfall card by `scryfall_id`.

  Uses `ON CONFLICT ... DO UPDATE` to avoid a SELECT per row,
  which matters at ~113k cards per Scryfall bulk import.
  """
  def upsert_scryfall_card!(attrs) do
    attrs = attrs |> Map.new() |> Map.update(:set_code, nil, &normalize_set_code/1)

    %ScryfallCard{}
    |> ScryfallCard.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:scryfall_id]
    )
  end

  defp normalize_set_code(nil), do: nil
  defp normalize_set_code(code) when is_binary(code), do: String.upcase(code)
end
