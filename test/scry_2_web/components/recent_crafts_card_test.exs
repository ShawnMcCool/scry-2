defmodule Scry2Web.RecentCraftsCardTest do
  use ExUnit.Case, async: true

  import Scry2Web.RecentCraftsCard, only: [card_name_for: 2, rarity_chip_class: 1]

  describe "card_name_for/2" do
    test "returns the :name field on a card struct/map" do
      cards = %{91_001 => %{name: "Lightning Bolt"}}
      assert card_name_for(cards, 91_001) == "Lightning Bolt"
    end

    test "returns the string-keyed name on a string-keyed map" do
      cards = %{91_001 => %{"name" => "Lightning Bolt"}}
      assert card_name_for(cards, 91_001) == "Lightning Bolt"
    end

    test "returns nil for an unknown arena_id" do
      assert card_name_for(%{}, 91_001) == nil
    end

    test "returns nil for a malformed entry" do
      cards = %{91_001 => :something_else}
      assert card_name_for(cards, 91_001) == nil
    end
  end

  describe "rarity_chip_class/1" do
    test "produces a soft-style class per rarity" do
      assert rarity_chip_class("common") =~ "bg-base-content/5"
      assert rarity_chip_class("uncommon") =~ "bg-blue-500/10"
      assert rarity_chip_class("rare") =~ "bg-amber-500/10"
      assert rarity_chip_class("mythic") =~ "bg-red-500/10"
    end

    test "falls back to a neutral chip for unknown rarities" do
      assert rarity_chip_class("bogus") =~ "bg-base-content/5"
    end
  end
end
