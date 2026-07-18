defmodule Scry2.Decks.CompositionIdentity do
  @moduledoc """
  Printing-insensitive identity for a constructed decklist.

  MTGA's `arena_id` identifies a specific *printing* of a card, so a card style
  swap, a re-import, or a clone can change a card's `arena_id` without changing
  the deck. Identifying a deck by raw `arena_id` composition therefore splits one
  decklist into several — see the split this module exists to prevent.

  This module collapses every printing of a card onto a single canonical
  `arena_id` (its name identity) before hashing, so all printings of the same
  card compare equal. It mirrors `Scry2.NetDecking.OwnedIdentity`, which already
  aggregates collection ownership across printings by name.

  Pure function — no DB. Inputs:

    * `cards` — a list of `%{arena_id, count}` maps (string- or atom-keyed)
    * `representative_by_arena_id` — `%{arena_id => canonical_arena_id}`, mapping
      every printing of a card onto one representative. Arena_ids absent from the
      map fall back to themselves (unknown cards keep their own identity).

  Output of `canonical_pairs/2`: a sorted list of `{representative, total_count}`,
  with counts summed across printings of the same card.
  """

  @type cards :: [map()]
  @type representatives :: %{optional(integer()) => integer()}

  @doc """
  Sorted `{representative_arena_id, total_count}` pairs for a decklist, with
  counts summed across printings that share a representative.
  """
  @spec canonical_pairs(cards(), representatives()) :: [{integer(), integer()}]
  def canonical_pairs(cards, representative_by_arena_id) when is_list(cards) do
    cards
    |> Enum.reduce(%{}, fn card, acc ->
      case pair(card, representative_by_arena_id) do
        nil -> acc
        {representative, count} -> Map.update(acc, representative, count, &(&1 + count))
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Stable hash of a decklist's canonical composition. `nil` when the list has no
  resolvable `arena_id`/`count` pairs. Stable across BEAM versions per
  `:erlang.phash2/1`.
  """
  @spec hash(cards(), representatives()) :: integer() | nil
  def hash(cards, representative_by_arena_id) when is_list(cards) do
    case canonical_pairs(cards, representative_by_arena_id) do
      [] -> nil
      pairs -> :erlang.phash2(pairs)
    end
  end

  defp pair(card, representative_by_arena_id) when is_map(card) do
    arena_id = card["arena_id"] || card[:arena_id]
    count = card["count"] || card[:count]

    if arena_id && count do
      {Map.get(representative_by_arena_id, arena_id, arena_id), count}
    end
  end

  defp pair(_, _), do: nil
end
