defmodule Scry2.Cards do
  @moduledoc """
  Context module for card reference data.

  Owns tables: `cards_cards`, `cards_sets`.

  PubSub role: broadcasts `"cards:updates"` after reference-data refreshes.

  See `Scry2.Cards.Lands17Importer` for the bulk import path. See ADR-014
  for the `arena_id` identity invariant.
  """

  import Ecto.Query

  alias Scry2.Cards.{Card, Set}
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
    Repo.aggregate(Card, :count, :id)
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
end
