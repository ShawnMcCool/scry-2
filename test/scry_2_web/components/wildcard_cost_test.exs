defmodule Scry2Web.WildcardCostTest do
  use ExUnit.Case, async: true

  alias Scry2Web.WildcardCost

  test "pips returns non-zero rarities as {rarity, count} in common→mythic order" do
    assert WildcardCost.pips(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) ==
             [{:uncommon, 2}, {:rare, 1}]

    assert WildcardCost.pips(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == []
  end

  test "any? reflects whether a cost map has non-zero rarities" do
    assert WildcardCost.any?(%{common: 0, uncommon: 0, rare: 1, mythic: 0})
    refute WildcardCost.any?(%{common: 0, uncommon: 0, rare: 0, mythic: 0})
  end

  test "format renders non-zero rarities compactly" do
    assert WildcardCost.format(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) == "2u 1r"
    assert WildcardCost.format(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == "—"
    assert WildcardCost.format(%{common: 1, uncommon: 0, rare: 0, mythic: 3}) == "1c 3m"
  end

  test "balances orders the pool common → mythic" do
    assert WildcardCost.balances(%{common: 1, uncommon: 2, rare: 3, mythic: 4}) ==
             [{:common, 1}, {:uncommon, 2}, {:rare, 3}, {:mythic, 4}]

    assert WildcardCost.balances(%{}) ==
             [{:common, 0}, {:uncommon, 0}, {:rare, 0}, {:mythic, 0}]
  end
end
