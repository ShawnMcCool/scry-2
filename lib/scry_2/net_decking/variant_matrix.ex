defmodule Scry2.NetDecking.VariantMatrix do
  @moduledoc """
  Pure derivation of the variant-matrix view model (UIDR-014): contested
  nonland cards × cluster members, every cell a copy-count delta relative
  to the viewed deck. No DB, no side effects.

  Identity is the card **name**, not the printing — two arena_ids sharing
  a name are one card (mirrors `OwnedIdentity`). Cards that don't resolve
  in the reference lookup are excluded entirely, never surfaced as
  "Unknown". Lands and sideboard changes are reduced to per-column
  magnitudes; only nonland main-deck differences become named rows.

  `build/3` input → output contract:
  input — the viewed deck, the cluster's member decks (any order, viewed
  deck tolerated and skipped), and the `arena_id => card` reference map.
  output — `%{rows, columns}` where each row is
  `%{name, rarity, you_count, contested_count}` sorted most-contested
  first (name as tie-break), and each column is
  `%{deck, deltas, lands_changed, sideboard_changed, total_changed}` in
  input order with `deltas` keyed by card name.
  """

  alias Scry2.NetDecking.Deck

  @type row :: %{
          name: String.t(),
          rarity: String.t() | nil,
          you_count: non_neg_integer(),
          contested_count: pos_integer()
        }
  @type column :: %{
          deck: Deck.t(),
          deltas: %{optional(String.t()) => integer()},
          lands_changed: non_neg_integer(),
          sideboard_changed: non_neg_integer(),
          total_changed: non_neg_integer()
        }

  @spec build(Deck.t(), [Deck.t()], %{optional(integer()) => map()}) :: %{
          rows: [row()],
          columns: [column()]
        }
  def build(%Deck{} = viewed_deck, member_decks, cards_by_arena_id) do
    viewed_main = counts_by_name(viewed_deck.main_deck, cards_by_arena_id)
    viewed_side = counts_by_name(viewed_deck.sideboard, cards_by_arena_id)

    columns =
      member_decks
      |> Enum.reject(fn member -> member.id == viewed_deck.id end)
      |> Enum.map(fn member -> column(member, viewed_main, viewed_side, cards_by_arena_id) end)

    %{rows: rows(columns, viewed_main, cards_by_arena_id), columns: columns}
  end

  # ── Columns ─────────────────────────────────────────────────────────

  defp column(member, viewed_main, viewed_side, cards_by_arena_id) do
    member_main = counts_by_name(member.main_deck, cards_by_arena_id)
    member_side = counts_by_name(member.sideboard, cards_by_arena_id)

    {spell_deltas, lands_changed} = main_deltas(viewed_main, member_main)
    sideboard_changed = changed_magnitude(viewed_side, member_side)

    spells_changed = spell_deltas |> Map.values() |> Enum.map(&abs/1) |> Enum.sum()

    %{
      deck: member,
      deltas: spell_deltas,
      lands_changed: lands_changed,
      sideboard_changed: sideboard_changed,
      total_changed: spells_changed + lands_changed + sideboard_changed
    }
  end

  defp main_deltas(viewed_main, member_main) do
    viewed_main
    |> all_names(member_main)
    |> Enum.reduce({%{}, 0}, fn {name, land?}, {deltas, lands} ->
      delta = count_for(member_main, name, land?) - count_for(viewed_main, name, land?)

      cond do
        delta == 0 -> {deltas, lands}
        land? -> {deltas, lands + abs(delta)}
        true -> {Map.put(deltas, name, delta), lands}
      end
    end)
  end

  defp changed_magnitude(viewed_counts, member_counts) do
    viewed_counts
    |> all_names(member_counts)
    |> Enum.map(fn {name, land?} ->
      abs(count_for(member_counts, name, land?) - count_for(viewed_counts, name, land?))
    end)
    |> Enum.sum()
  end

  # ── Rows ────────────────────────────────────────────────────────────

  defp rows(columns, viewed_main, cards_by_arena_id) do
    rarities_by_name =
      Map.new(cards_by_arena_id, fn {_arena_id, card} -> {card.name, card.rarity} end)

    columns
    |> Enum.flat_map(fn column -> Map.keys(column.deltas) end)
    |> Enum.frequencies()
    |> Enum.map(fn {name, contested_count} ->
      %{
        name: name,
        rarity: Map.get(rarities_by_name, name),
        you_count: count_for(viewed_main, name, false),
        contested_count: contested_count
      }
    end)
    |> Enum.sort_by(fn row -> {-row.contested_count, row.name} end)
  end

  # ── Card-list normalization ─────────────────────────────────────────

  # `{name, land?} => copies`, resolved by name identity; unresolved
  # arena_ids are dropped here, which excludes them from the whole matrix.
  defp counts_by_name(card_list, cards_by_arena_id) do
    card_list
    |> card_entries()
    |> Enum.reduce(%{}, fn entry, counts ->
      case Map.get(cards_by_arena_id, entry.arena_id) do
        nil -> counts
        card -> Map.update(counts, {card.name, land?(card)}, entry.count, &(&1 + entry.count))
      end
    end)
  end

  defp all_names(counts_a, counts_b) do
    MapSet.union(MapSet.new(Map.keys(counts_a)), MapSet.new(Map.keys(counts_b)))
  end

  defp count_for(counts, name, land?), do: Map.get(counts, {name, land?}, 0)

  defp land?(%{is_land: true}), do: true
  defp land?(_card), do: false

  defp card_entries(%{"cards" => cards}) when is_list(cards) do
    Enum.map(cards, fn card ->
      %{arena_id: card["arena_id"] || card[:arena_id], count: card["count"] || card[:count]}
    end)
  end

  defp card_entries(_card_list), do: []
end
