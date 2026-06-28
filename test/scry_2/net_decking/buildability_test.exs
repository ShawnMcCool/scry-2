defmodule Scry2.NetDecking.BuildabilityTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Buildability

  test "card_shortage returns missing copies, excluding free arena_ids" do
    deck = [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}, %{arena_id: 99, count: 8}]
    owned = %{1 => 4, 2 => 1}
    free = MapSet.new([99])

    assert Buildability.card_shortage(deck, owned, free) == [{2, 3}]
  end

  test "rarity_buckets sums missing copies by rarity" do
    shortages = [{2, 3}, {3, 2}, {4, 1}]
    rarities = %{2 => "uncommon", 3 => "rare", 4 => "rare"}

    assert Buildability.rarity_buckets(shortages, rarities) ==
             %{common: 0, uncommon: 3, rare: 3, mythic: 0}
  end
end
