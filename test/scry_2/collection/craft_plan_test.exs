defmodule Scry2.Collection.CraftPlanTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.{CraftPlan, Holding}
  alias Scry2.Collection.Snapshot
  alias Scry2.TestFactory

  defp holding(arena_id, count, attrs) do
    card = TestFactory.build_card(Map.merge(%{arena_id: arena_id}, attrs))

    %Holding{
      arena_id: arena_id,
      count: count,
      card: card,
      copies_to_playset: max(4 - count, 0)
    }
  end

  defp snapshot(wildcards) do
    struct(Snapshot, Map.merge(%{cards_json: "[]"}, wildcards))
  end

  describe "from_holdings/2" do
    test "lists cards with fewer than four total copies (by name) as incomplete playsets" do
      holdings = [
        holding(60_001, 4, %{rarity: "common", name: "Common A"}),
        holding(60_002, 2, %{rarity: "rare", name: "Rare A"}),
        holding(60_003, 1, %{rarity: "mythic", name: "Mythic A"}),
        holding(60_004, 3, %{rarity: "uncommon", name: "Uncommon A"})
      ]

      plan = CraftPlan.from_holdings(holdings, snapshot(%{}))

      names = Enum.map(plan.incomplete_playsets, & &1.holding.card.name)
      refute "Common A" in names
      assert "Rare A" in names
      assert "Mythic A" in names
      assert "Uncommon A" in names
    end

    test "rolls up copies across reprint printings — a 4+ by-name total is not incomplete" do
      # MTGA caps playsets by name across reprints. A user with 4 copies
      # of Essence Scatter from DMU plus 0 from SOS is complete on
      # Essence Scatter — neither holding should appear here.
      holdings = [
        holding(60_100, 4, %{rarity: "common", name: "Essence Scatter"}),
        holding(60_101, 0, %{rarity: "common", name: "Essence Scatter"})
      ]

      plan = CraftPlan.from_holdings(holdings, snapshot(%{}))

      assert plan.incomplete_playsets == []
    end

    test "rolls up partial copies across reprint printings into a single incomplete-playset row" do
      # 1 SOS + 2 DMU = 3 by name. One row, copies_needed = 1, not two
      # rows each suggesting their own gap. The display holding shows
      # the printing the player owns the most of.
      holdings = [
        holding(60_200, 1, %{rarity: "common", name: "Essence Scatter"}),
        holding(60_201, 2, %{rarity: "common", name: "Essence Scatter"})
      ]

      plan = CraftPlan.from_holdings(holdings, snapshot(%{}))

      assert [row] = plan.incomplete_playsets
      assert row.holding.card.name == "Essence Scatter"
      assert row.holding.arena_id == 60_201
      assert row.copies_needed == 1
    end

    test "sorts incomplete playsets mythic, rare, uncommon, common, then by name" do
      holdings = [
        holding(61_001, 1, %{rarity: "common", name: "Bear"}),
        holding(61_002, 1, %{rarity: "rare", name: "Bolt"}),
        holding(61_003, 1, %{rarity: "rare", name: "Aether"}),
        holding(61_004, 1, %{rarity: "mythic", name: "Drake"}),
        holding(61_005, 1, %{rarity: "uncommon", name: "Cat"})
      ]

      plan = CraftPlan.from_holdings(holdings, snapshot(%{}))

      assert Enum.map(plan.incomplete_playsets, & &1.holding.card.name) ==
               ["Drake", "Aether", "Bolt", "Cat", "Bear"]
    end

    test "skips basics (is_land and is_booster=false) — wildcards do not apply" do
      holdings = [
        holding(62_001, 1, %{rarity: "common", is_land: true, is_booster: false, name: "Forest"}),
        holding(62_002, 1, %{rarity: "common", is_land: true, is_booster: true, name: "Shockland"}),
        holding(62_003, 1, %{rarity: "rare", is_booster: true, name: "Spell"})
      ]

      plan = CraftPlan.from_holdings(holdings, snapshot(%{}))

      names = Enum.map(plan.incomplete_playsets, & &1.holding.card.name)
      refute "Forest" in names
      assert "Shockland" in names
      assert "Spell" in names
    end

    test "computes wildcards_owned and wildcards_needed_by_rarity" do
      holdings = [
        holding(63_001, 2, %{rarity: "rare", is_booster: true, name: "Rare A"}),
        holding(63_002, 1, %{rarity: "rare", is_booster: true, name: "Rare B"}),
        holding(63_003, 1, %{rarity: "mythic", is_booster: true, name: "Mythic A"}),
        holding(63_004, 4, %{rarity: "common", is_booster: true, name: "Common A"})
      ]

      plan =
        CraftPlan.from_holdings(
          holdings,
          snapshot(%{
            wildcards_common: 0,
            wildcards_uncommon: 5,
            wildcards_rare: 1,
            wildcards_mythic: 0
          })
        )

      assert plan.wildcards_owned == %{
               "common" => 0,
               "uncommon" => 5,
               "rare" => 1,
               "mythic" => 0
             }

      # rare gap: 2 + 3 = 5; mythic gap: 3
      assert plan.wildcards_needed_by_rarity == %{"rare" => 5, "mythic" => 3}
    end

    test "treats nil wildcard fields (fallback_scan path) as zero" do
      plan =
        CraftPlan.from_holdings(
          [holding(64_001, 1, %{rarity: "rare", is_booster: true})],
          snapshot(%{
            wildcards_common: nil,
            wildcards_uncommon: nil,
            wildcards_rare: nil,
            wildcards_mythic: nil
          })
        )

      assert plan.wildcards_owned == %{
               "common" => 0,
               "uncommon" => 0,
               "rare" => 0,
               "mythic" => 0
             }
    end

    test "returns an empty plan when there are no holdings" do
      plan = CraftPlan.from_holdings([], snapshot(%{}))

      assert plan.incomplete_playsets == []
      assert plan.wildcards_needed_by_rarity == %{}
    end
  end
end
