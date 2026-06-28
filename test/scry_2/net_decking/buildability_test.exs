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

  test "affordability returns per-rarity shortfall, never paying across rarities" do
    cost = %{common: 0, uncommon: 2, rare: 3, mythic: 1}
    wildcards = %{common: 10, uncommon: 5, rare: 1, mythic: 0}

    assert Buildability.affordability(cost, wildcards) ==
             %{common: 0, uncommon: 0, rare: 2, mythic: 1}
  end

  test "classify_status: buildable when cost is zero" do
    assert Buildability.classify_status(%{common: 0, uncommon: 0, rare: 0, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 0,
             mythic: 0
           }) == :buildable
  end

  test "classify_status: craftable when cost > 0 but shortfall is zero" do
    assert Buildability.classify_status(%{common: 0, uncommon: 2, rare: 0, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 0,
             mythic: 0
           }) == :craftable
  end

  test "classify_status: short when any rarity falls short" do
    assert Buildability.classify_status(%{common: 0, uncommon: 0, rare: 3, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 2,
             mythic: 0
           }) == :short
  end
end
