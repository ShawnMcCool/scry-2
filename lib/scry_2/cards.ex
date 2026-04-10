defmodule Scry2.Cards do
  @moduledoc """
  Context module for card reference data.

  Owns tables: `cards_cards`, `cards_sets`, `cards_scryfall_cards`, `cards_mtga_cards`.

  PubSub role: broadcasts `"cards:updates"` after reference-data refreshes.

  See `Scry2.Cards.SeventeenLands` for the bulk import path. See ADR-014
  for the `arena_id` identity invariant.
  """

  import Ecto.Query

  alias Scry2.Cards.{Card, MtgaCard, ScryfallCard, Set}
  alias Scry2.Repo

  # ── Sets ────────────────────────────────────────────────────────────────

  @doc "Returns the set with the given `code`, or nil."
  def get_set_by_code(code) when is_binary(code) do
    Repo.get_by(Set, code: code)
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

  Keys: `:lands17_count`, `:lands17_bytes`, `:scryfall_count`, `:scryfall_bytes`,
        `:db_bytes`, `:image_count`, `:image_bytes`.
  """
  def data_source_stats do
    image_cache_dir = Scry2.Config.get(:image_cache_dir)
    {image_count, image_bytes} = image_cache_stats(image_cache_dir)

    %{
      lands17_count: Repo.aggregate(Card, :count),
      scryfall_count: Repo.aggregate(ScryfallCard, :count),
      lands17_bytes: table_size_bytes("cards_cards"),
      scryfall_bytes: table_size_bytes("cards_scryfall_cards"),
      db_bytes: db_file_size(),
      image_count: image_count,
      image_bytes: image_bytes
    }
  end

  @doc """
  Returns the last `updated_at` for each card data source.

  Keys: `:lands17_updated_at`, `:scryfall_updated_at` (both may be nil).
  """
  def import_timestamps do
    %{
      lands17_updated_at: from(c in Card, select: max(c.updated_at)) |> Repo.one(),
      scryfall_updated_at: from(c in ScryfallCard, select: max(c.updated_at)) |> Repo.one()
    }
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
    ids_query = from q in subquery(query), group_by: q.name, select: min(q.id)
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

  @doc """
  Sets `arena_id` on a card that doesn't have one yet.

  Returns `{:ok, card}` if the backfill happened or was a no-op
  (card already has an arena_id). Raises on DB errors.

  ADR-014: never overwrites an existing arena_id.
  """
  def backfill_arena_id!(%Card{arena_id: existing} = card, _arena_id)
      when not is_nil(existing) do
    {:ok, card}
  end

  def backfill_arena_id!(%Card{arena_id: nil} = card, arena_id)
      when is_integer(arena_id) do
    updated =
      card
      |> Card.scryfall_changeset(%{arena_id: arena_id})
      |> Repo.update!()

    {:ok, updated}
  end

  @doc """
  Returns cards matching the given name and set code, or empty list.
  """
  def get_by_name_and_set(name, set_code)
      when is_binary(name) and is_binary(set_code) do
    from(c in Card,
      join: s in assoc(c, :set),
      where: c.name == ^name and s.code == ^set_code
    )
    |> Repo.all()
  end

  @doc "Returns the card for the given MTGA arena_id, or nil."
  def get_by_arena_id(arena_id) when is_integer(arena_id) do
    Repo.get_by(Card, arena_id: arena_id)
  end

  @doc """
  Returns a map of arena_id => card data for a list of arena_ids.

  Queries `cards_cards` (17lands) first for rich data (human-readable types,
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

  # Decodes MTGA's comma-separated integer type enums to a space-separated
  # human-readable string (e.g. "2,5" → "Creature Land"). Used only for
  # MtgaCard fallback entries where 17lands data is unavailable.
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

  @doc "Returns the card for the given 17lands lands17_id, or nil."
  def get_by_lands17_id(lands17_id) when is_integer(lands17_id) do
    Repo.get_by(Card, lands17_id: lands17_id)
  end

  @doc """
  Upserts a card by `lands17_id` (the 17lands primary import key).

  Never mutates an existing row's `arena_id` — see ADR-014.
  """
  def upsert_card!(attrs) do
    attrs = Map.new(attrs)

    case get_by_lands17_id(attrs.lands17_id) do
      nil ->
        %Card{}
        |> Card.lands17_changeset(attrs)
        |> Repo.insert!()

      existing ->
        # Don't clobber arena_id if already set.
        attrs = maybe_preserve_arena_id(attrs, existing)

        existing
        |> Card.lands17_changeset(attrs)
        |> Repo.update!()
    end
  end

  defp maybe_preserve_arena_id(attrs, %Card{arena_id: nil}), do: attrs

  defp maybe_preserve_arena_id(attrs, %Card{arena_id: existing_id}) do
    Map.put(attrs, :arena_id, existing_id)
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

  @doc "Returns the Scryfall card for the given scryfall_id, or nil."
  def get_scryfall_by_scryfall_id(scryfall_id) when is_binary(scryfall_id) do
    Repo.get_by(ScryfallCard, scryfall_id: scryfall_id)
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
    attrs = Map.new(attrs)

    %ScryfallCard{}
    |> ScryfallCard.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:scryfall_id]
    )
  end
end
