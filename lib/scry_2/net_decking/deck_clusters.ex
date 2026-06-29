defmodule Scry2.NetDecking.DeckClusters do
  @moduledoc """
  Pure near-duplicate grouping of decks. Each input item is
  `%{id, set: MapSet, weight: number}` where `set` is the deck's nonland card
  identity and `weight` ranks representativeness (lower = preferred; the caller
  passes total wildcard cost so the most buildable variant represents the
  cluster).

  `group/2` greedily assigns each item to the first cluster whose representative
  set has Jaccard similarity >= threshold, else starts a new cluster. After
  assignment, each cluster's representative is its lowest-weight member.
  Returns `[%{representative_id, member_ids, count}]`. No DB.
  """

  @spec group([map()], float()) :: [
          %{representative_id: any(), member_ids: [any()], count: non_neg_integer()}
        ]
  def group(items, threshold) do
    items
    |> Enum.reduce([], fn item, clusters ->
      case Enum.find_index(clusters, fn c -> jaccard(item.set, c.seed_set) >= threshold end) do
        nil -> clusters ++ [%{seed_set: item.set, members: [item]}]
        idx -> List.update_at(clusters, idx, fn c -> %{c | members: [item | c.members]} end)
      end
    end)
    |> Enum.map(fn %{members: members} ->
      rep = Enum.min_by(members, & &1.weight)
      %{representative_id: rep.id, member_ids: Enum.map(members, & &1.id), count: length(members)}
    end)
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end
end
