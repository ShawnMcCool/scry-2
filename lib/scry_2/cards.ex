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
  alias Scry2.Settings

  @lands17_refresh_key "cards_lands17_last_refresh_at"
  @scryfall_refresh_key "cards_scryfall_last_refresh_at"

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
  Returns the last **successful refresh** timestamp for each card data
  source.

  This intentionally tracks refresh *runs*, not `updated_at` on the card
  rows. When the upstream CSV/bulk data hasn't changed between imports,
  Ecto's changeset comparison produces zero-change updates and row
  `updated_at` doesn't advance — but "we verified the data is still
  current" is exactly what the Health freshness check needs.

  Stored via `Scry2.Settings` (SQLite JSON blob). Keys are
  `cards_lands17_last_refresh_at` and `cards_scryfall_last_refresh_at`.

  Keys in the returned map: `:lands17_updated_at`, `:scryfall_updated_at`
  (both may be nil). Name is preserved for consumer stability even
  though "updated_at" is now a soft alias for "last refresh".
  """
  def import_timestamps do
    %{
      lands17_updated_at: read_refresh_timestamp(@lands17_refresh_key),
      scryfall_updated_at: read_refresh_timestamp(@scryfall_refresh_key)
    }
  end

  @doc """
  Records a successful 17lands import at the current UTC time. Called
  from `Scry2.Workers.PeriodicallyUpdateCards` after a successful run.
  """
  @spec record_lands17_refresh!(DateTime.t()) :: :ok
  def record_lands17_refresh!(now \\ DateTime.utc_now()) do
    Settings.put!(@lands17_refresh_key, DateTime.to_iso8601(now))
    :ok
  end

  @doc """
  Records a successful Scryfall backfill at the current UTC time. Called
  from `Scry2.Workers.PeriodicallyBackfillArenaIds` after a successful run.
  """
  @spec record_scryfall_refresh!(DateTime.t()) :: :ok
  def record_scryfall_refresh!(now \\ DateTime.utc_now()) do
    Settings.put!(@scryfall_refresh_key, DateTime.to_iso8601(now))
    :ok
  end

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
  Backfills `arena_id` on `cards_cards` rows using MTGA client data.

  Two passes are run, each targeting cards whose `arena_id` is not yet set:

  **Pass 1 — Scryfall-mediated:** joins `cards_mtga_cards` → `cards_scryfall_cards`
  via `(expansion_code, collector_number)` to get the Scryfall name (handles
  DFC " // " naming). Works when MTGA and Scryfall share the same set code.

  **Pass 2 — Direct MTGA name:** matches `cards_mtga_cards` directly to
  `cards_cards` via `(name, expansion_code)`, bypassing Scryfall entirely.
  Catches cards where MTGA and Scryfall use different set codes for the same
  set (e.g., MTGA "Y24" vs Scryfall "YMKM").

  Complements the Scryfall-based backfill in `Scry2.Cards.Scryfall`.
  ADR-014: never overwrites an existing `arena_id`.

  Returns the count of newly backfilled arena_ids.
  """
  def backfill_arena_ids_from_client_data! do
    count = backfill_via_scryfall_name(0)
    backfill_via_direct_name(count)
  end

  # Pass 1: mtga_cards → scryfall_cards (for name) → cards_cards.
  # Works when the set code matches between MTGA and Scryfall.
  defp backfill_via_scryfall_name(count) do
    pairs =
      from(mc in "cards_mtga_cards",
        join: sc in "cards_scryfall_cards",
        on:
          sc.set_code == mc.expansion_code and
            sc.collector_number == mc.collector_number,
        left_join: existing in Card,
        on: existing.arena_id == mc.arena_id,
        where: is_nil(existing.id),
        select: %{
          arena_id: mc.arena_id,
          front_name:
            fragment(
              "CASE WHEN instr(?, ' // ') > 0 THEN substr(?, 1, instr(?, ' // ') - 1) ELSE ? END",
              sc.name,
              sc.name,
              sc.name,
              sc.name
            ),
          set_code: mc.expansion_code
        },
        distinct: true
      )
      |> Repo.all()

    apply_backfill_pairs(pairs, count)
  end

  # Pass 2: mtga_cards → cards_cards directly by (name, expansion_code).
  # Catches cards where MTGA and Scryfall use different set code aliases
  # (e.g., MTGA "Y24" vs Scryfall "YMKM"). Skips blank/unknown names.
  defp backfill_via_direct_name(count) do
    pairs =
      from(mc in "cards_mtga_cards",
        left_join: existing in Card,
        on: existing.arena_id == mc.arena_id,
        where:
          is_nil(existing.id) and mc.name != "" and
            not like(mc.name, "Unknown %"),
        select: %{
          arena_id: mc.arena_id,
          front_name:
            fragment(
              "CASE WHEN instr(?, ' // ') > 0 THEN substr(?, 1, instr(?, ' // ') - 1) ELSE ? END",
              mc.name,
              mc.name,
              mc.name,
              mc.name
            ),
          set_code: mc.expansion_code
        },
        distinct: true
      )
      |> Repo.all()

    apply_backfill_pairs(pairs, count)
  end

  defp apply_backfill_pairs(pairs, initial_count) do
    Enum.reduce(pairs, initial_count, fn %{
                                           arena_id: arena_id,
                                           front_name: name,
                                           set_code: set_code
                                         },
                                         count ->
      case get_by_name_and_set(name, set_code) do
        [] ->
          count

        cards ->
          card = Enum.find(cards, &is_nil(&1.arena_id))

          if card do
            try do
              {:ok, _} = backfill_arena_id!(card, arena_id)
              count + 1
            rescue
              _error in [Ecto.ConstraintError, Ecto.InvalidChangesetError] -> count
            end
          else
            count
          end
      end
    end)
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
  Returns the Scryfall "normal" image URL for an arena_id, or nil if not found.

  Tries two join paths (in order):
  1. Direct: `cards_scryfall_cards.arena_id` — works for any card Scryfall tags
     with an arena_id, regardless of set code naming differences.
  2. Fallback: `cards_mtga_cards` → `cards_scryfall_cards` via `(expansion_code,
     collector_number)` — catches cards where Scryfall lacks the arena_id field
     but the set codes match.

  Used by `ImageCache` to avoid redundant Scryfall API calls.
  """
  def get_image_url_for_arena_id(arena_id) when is_integer(arena_id) do
    direct =
      Repo.one(
        from sc in "cards_scryfall_cards",
          where: sc.arena_id == ^arena_id,
          select: fragment("json_extract(?, '$.normal')", sc.image_uris),
          limit: 1
      )

    direct ||
      Repo.one(
        from mc in "cards_mtga_cards",
          join: sc in "cards_scryfall_cards",
          on:
            sc.set_code == mc.expansion_code and
              sc.collector_number == mc.collector_number,
          where: mc.arena_id == ^arena_id,
          select: fragment("json_extract(?, '$.normal')", sc.image_uris),
          limit: 1
      ) ||
      Repo.one(
        from cc in "cards_cards",
          join: sc in "cards_scryfall_cards",
          on: sc.name == cc.name,
          where:
            cc.arena_id == ^arena_id and
              not is_nil(fragment("json_extract(?, '$.normal')", sc.image_uris)),
          select: fragment("json_extract(?, '$.normal')", sc.image_uris),
          limit: 1
      )
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

  @doc """
  Returns a map of `arena_id => card_name` for the given arena_ids.
  Resolves from both `cards_cards` (17lands) and `cards_mtga_cards` (MTGA).
  """
  def names_by_arena_ids(arena_ids) when is_list(arena_ids) do
    list_by_arena_ids(arena_ids)
    |> Map.new(fn {arena_id, card} ->
      name = if is_map(card), do: Map.get(card, :name) || card[:name], else: nil
      {arena_id, name}
    end)
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
