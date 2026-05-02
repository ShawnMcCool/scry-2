defmodule Scry2.Crafts.AttributeCrafts do
  @moduledoc """
  Pure attribution: turns a pair of consecutive collection snapshots
  into a list of `%Scry2.Crafts.Attribution{}` for any clean
  single-card wildcard crafts that occurred between them.

  Attribution rule (v1, ADR-037):

    * Both snapshots must have walker-populated wildcard counts. If
      either side is `nil` (scanner fallback), produce no attributions.
    * For each rarity whose total decreased, the spend is unambiguous
      — only crafting decrements `wildcards_<rarity>`.
    * Attribute that spend to a card iff exactly one card of the
      matching rarity gained copies in the window AND its gain count
      equals the wildcard spend. Otherwise skip — the snapshots stay
      in the DB so a smarter v2 can re-process.

  This module is pure: no DB, no PubSub, no logging. The caller is
  expected to pass a precomputed `arena_id -> rarity` map covering at
  least every arena_id whose count changed; arena_ids not in the map
  are treated as unknown rarity and contribute to no attribution.
  """

  alias Scry2.Collection.Snapshot
  alias Scry2.Crafts.Attribution

  @rarities [:common, :uncommon, :rare, :mythic]

  @type rarity :: Attribution.rarity()
  @type rarities_by_arena_id :: %{integer() => rarity()}

  @spec attribute(Snapshot.t() | nil, Snapshot.t(), rarities_by_arena_id()) :: [Attribution.t()]
  def attribute(nil, _next, _rarities), do: []

  def attribute(%Snapshot{} = prev, %Snapshot{} = next, rarities) when is_map(rarities) do
    if has_walker_wildcards?(prev) and has_walker_wildcards?(next) do
      do_attribute(prev, next, rarities)
    else
      []
    end
  end

  defp do_attribute(prev, next, rarities) do
    case wildcard_decreases(prev, next) do
      decreases when map_size(decreases) == 0 ->
        []

      decreases ->
        gains = card_gains(prev, next)

        Enum.flat_map(decreases, fn {rarity, spend_qty} ->
          attribute_one(rarity, spend_qty, gains, rarities)
        end)
    end
  end

  defp attribute_one(rarity, spend_qty, gains, rarities) do
    candidates =
      Enum.filter(gains, fn {arena_id, _qty} ->
        Map.get(rarities, arena_id) == rarity
      end)

    case candidates do
      [{arena_id, qty}] when qty == spend_qty ->
        [%Attribution{arena_id: arena_id, rarity: rarity, quantity: spend_qty}]

      _ ->
        []
    end
  end

  defp wildcard_decreases(prev, next) do
    Enum.reduce(@rarities, %{}, fn rarity, acc ->
      prev_count = Map.fetch!(prev, :"wildcards_#{rarity}")
      next_count = Map.fetch!(next, :"wildcards_#{rarity}")

      if next_count < prev_count do
        Map.put(acc, rarity, prev_count - next_count)
      else
        acc
      end
    end)
  end

  defp card_gains(prev, next) do
    prev_counts = decode_entries(prev)
    next_counts = decode_entries(next)

    arena_ids =
      prev_counts
      |> Map.keys()
      |> Enum.concat(Map.keys(next_counts))
      |> Enum.uniq()

    Enum.reduce(arena_ids, %{}, fn arena_id, acc ->
      old_count = Map.get(prev_counts, arena_id, 0)
      new_count = Map.get(next_counts, arena_id, 0)

      if new_count > old_count do
        Map.put(acc, arena_id, new_count - old_count)
      else
        acc
      end
    end)
  end

  defp decode_entries(%Snapshot{cards_json: nil}), do: %{}

  defp decode_entries(%Snapshot{cards_json: json}) when is_binary(json) do
    json
    |> Snapshot.decode_entries()
    |> Map.new()
  end

  defp has_walker_wildcards?(%Snapshot{} = snap) do
    not is_nil(snap.wildcards_common) and
      not is_nil(snap.wildcards_uncommon) and
      not is_nil(snap.wildcards_rare) and
      not is_nil(snap.wildcards_mythic)
  end
end
