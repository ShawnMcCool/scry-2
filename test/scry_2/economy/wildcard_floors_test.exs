defmodule Scry2.Economy.WildcardFloorsTest do
  use ExUnit.Case, async: true

  alias Scry2.Economy.WildcardFloors

  defp inv(common, uncommon, rare, mythic) do
    %{
      wildcards_common: common,
      wildcards_uncommon: uncommon,
      wildcards_rare: rare,
      wildcards_mythic: mythic
    }
  end

  describe "default_floors/0" do
    test "returns the default floor for each rarity" do
      assert WildcardFloors.default_floors() == %{
               common: 50,
               uncommon: 30,
               rare: 15,
               mythic: 5
             }
    end
  end

  describe "below_floor/1" do
    test "returns empty list when every rarity is above its floor" do
      assert WildcardFloors.below_floor(inv(100, 80, 50, 20)) == []
    end

    test "flags a rarity at or below its floor with the floor and count" do
      result = WildcardFloors.below_floor(inv(100, 80, 50, 5))

      assert result == [%{rarity: :mythic, count: 5, floor: 5}]
    end

    test "flags multiple rarities ordered by rarity (mythic last is most severe)" do
      result = WildcardFloors.below_floor(inv(40, 20, 10, 3))

      assert result == [
               %{rarity: :common, count: 40, floor: 50},
               %{rarity: :uncommon, count: 20, floor: 30},
               %{rarity: :rare, count: 10, floor: 15},
               %{rarity: :mythic, count: 3, floor: 5}
             ]
    end

    test "treats nil counts as zero (and therefore below floor)" do
      result = WildcardFloors.below_floor(inv(nil, nil, nil, nil))

      assert Enum.map(result, & &1.rarity) == [:common, :uncommon, :rare, :mythic]
      assert Enum.all?(result, &(&1.count == 0))
    end

    test "returns empty list for nil inventory" do
      assert WildcardFloors.below_floor(nil) == []
    end
  end

  describe "below_floor?/1" do
    test "true when any rarity is below floor" do
      assert WildcardFloors.below_floor?(inv(100, 80, 50, 4)) == true
    end

    test "false when all rarities are above floor" do
      assert WildcardFloors.below_floor?(inv(100, 80, 50, 10)) == false
    end

    test "false for nil inventory" do
      assert WildcardFloors.below_floor?(nil) == false
    end
  end

  describe "rarity_below?/2" do
    test "true when rarity at-or-below floor" do
      assert WildcardFloors.rarity_below?(inv(40, 80, 50, 20), :common) == true
      assert WildcardFloors.rarity_below?(inv(50, 80, 50, 20), :common) == true
    end

    test "false when above floor" do
      assert WildcardFloors.rarity_below?(inv(51, 80, 50, 20), :common) == false
    end

    test "false for nil inventory" do
      assert WildcardFloors.rarity_below?(nil, :rare) == false
    end
  end
end
