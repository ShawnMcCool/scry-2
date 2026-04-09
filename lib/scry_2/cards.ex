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
  Lists cards with optional filters.

  Supported filters:
    * `:set_code` — filter by set code
    * `:rarity`   — filter by rarity string
    * `:name_like` — ILIKE-style substring match on name
    * `:limit`    — cap result count (default 100)
    * `:order_by` — `:name` (default) or `:arena_id`
  """
  def list_cards(filters \\ %{}) do
    filters = Map.new(filters)

    Card
    |> filter_by_set(filters[:set_code])
    |> filter_by_rarity(filters[:rarity])
    |> filter_by_name(filters[:name_like])
    |> order_by_field(Map.get(filters, :order_by, :name))
    |> limit(^Map.get(filters, :limit, 100))
    |> Repo.all()
  end

  defp filter_by_set(query, nil), do: query

  defp filter_by_set(query, code) when is_binary(code) do
    from c in query,
      join: s in assoc(c, :set),
      where: s.code == ^code
  end

  defp filter_by_rarity(query, nil), do: query
  defp filter_by_rarity(query, rarity), do: where(query, [c], c.rarity == ^rarity)

  defp filter_by_name(query, nil), do: query

  defp filter_by_name(query, term) when is_binary(term) do
    pattern = "%#{term}%"
    where(query, [c], like(c.name, ^pattern))
  end

  defp order_by_field(query, :arena_id), do: order_by(query, [c], asc: c.arena_id)
  defp order_by_field(query, _), do: order_by(query, [c], asc: c.name)

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
