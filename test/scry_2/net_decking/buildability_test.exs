defmodule Scry2.NetDecking.BuildabilityTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Buildability
  alias Scry2.NetDecking.Buildability.{Inputs, Result, Section}

  test "default_free_ids returns basic-land arena_ids, treating nameless cards as non-basic" do
    cards = %{
      1 => %{name: "Mountain"},
      2 => %{name: "Lightning Bolt"},
      3 => %{name: "Forest"},
      4 => %{}
    }

    assert Buildability.default_free_ids(cards) == MapSet.new([1, 3])
  end

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

  test "sort_key orders by mythic, rare, uncommon, common, then total" do
    assert Buildability.sort_key(%{common: 1, uncommon: 0, rare: 0, mythic: 0}) == {0, 0, 0, 1, 1}
    assert Buildability.sort_key(%{common: 0, uncommon: 0, rare: 0, mythic: 1}) == {1, 0, 0, 0, 1}
  end

  test "score produces a buildable result when everything is owned (basics free)" do
    inputs = %Inputs{
      main_cards: [%{arena_id: 1, count: 4}, %{arena_id: 99, count: 12}],
      side_cards: [],
      owned: %{1 => 4},
      wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      rarities: %{1 => "rare"},
      free_arena_ids: MapSet.new([99])
    }

    assert %Result{status: :buildable, maindeck: %Section{} = main} = Buildability.score(inputs)
    assert main.wildcard_cost == %{common: 0, uncommon: 0, rare: 0, mythic: 0}
    assert main.owned_pct == 1.0
    assert main.total_copies == 16
    assert main.missing_copies == 0
  end

  test "score produces a craftable result when wildcards on hand cover the cost" do
    inputs = %Inputs{
      main_cards: [%{arena_id: 1, count: 4}],
      side_cards: [],
      owned: %{1 => 2},
      wildcards: %{common: 0, uncommon: 0, rare: 5, mythic: 0},
      rarities: %{1 => "rare"},
      free_arena_ids: MapSet.new()
    }

    assert %Result{status: :craftable, maindeck: main} = Buildability.score(inputs)
    assert main.wildcard_cost == %{common: 0, uncommon: 0, rare: 2, mythic: 0}
    assert main.missing_copies == 2
  end

  test "score produces a short result and sort_key from the maindeck cost" do
    inputs = %Inputs{
      main_cards: [%{arena_id: 1, count: 4}],
      side_cards: [],
      owned: %{},
      wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      rarities: %{1 => "mythic"},
      free_arena_ids: MapSet.new()
    }

    assert %Result{status: :short, sort_key: {4, 0, 0, 0, 4}} = Buildability.score(inputs)
  end
end
