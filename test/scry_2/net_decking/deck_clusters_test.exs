defmodule Scry2.NetDecking.DeckClustersTest do
  use ExUnit.Case, async: true
  alias Scry2.NetDecking.DeckClusters

  defp item(id, ids, weight), do: %{id: id, set: MapSet.new(ids), weight: weight}

  test "groups items above the Jaccard threshold; representative = lowest weight" do
    items = [
      item(:a, [1, 2, 3, 4], 5),
      item(:b, [1, 2, 3, 5], 2),
      item(:c, [9, 8, 7, 6], 0)
    ]

    clusters = DeckClusters.group(items, 0.5)

    ab = Enum.find(clusters, &(&1.count == 2))
    assert ab.representative_id == :b
    assert Enum.sort(ab.member_ids) == [:a, :b]

    solo = Enum.find(clusters, &(&1.count == 1))
    assert solo.representative_id == :c
  end

  test "below-threshold items each form their own cluster" do
    items = [item(:a, [1, 2, 3, 4], 1), item(:b, [1, 5, 6, 7], 1)]
    assert length(DeckClusters.group(items, 0.5)) == 2
  end
end
