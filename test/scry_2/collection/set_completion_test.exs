defmodule Scry2.Collection.SetCompletionTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.{Holding, SetCompletion}
  alias Scry2.TestFactory

  defp card(arena_id, rarity, set_id) do
    TestFactory.build_card(%{arena_id: arena_id, rarity: rarity, set_id: set_id})
  end

  defp holding(card, count) do
    %Holding{
      arena_id: card.arena_id,
      count: count,
      card: card,
      copies_to_playset: max(4 - count, 0)
    }
  end

  describe "from/3" do
    test "partitions set cards into missing, partial, and complete buckets" do
      set = TestFactory.build_set(%{id: 1, code: "BLB", name: "Bloomburrow"})

      m1 = card(70_001, "mythic", set.id)
      r1 = card(70_002, "rare", set.id)
      r2 = card(70_003, "rare", set.id)
      u1 = card(70_004, "uncommon", set.id)
      c1 = card(70_005, "common", set.id)

      holdings = [
        # complete playset of m1
        holding(m1, 4),
        # partial: 2 of r1
        holding(r1, 2),
        # complete: 5 of u1 (over playset still counts as complete)
        holding(u1, 5)
        # r2 and c1 have no holding → missing
      ]

      result = SetCompletion.from(set, [m1, r1, r2, u1, c1], holdings)

      missing_ids = Enum.map(result.buckets.missing, & &1.arena_id) |> Enum.sort()
      partial_ids = Enum.map(result.buckets.partial, & &1.arena_id) |> Enum.sort()
      complete_ids = Enum.map(result.buckets.complete, & &1.arena_id) |> Enum.sort()

      assert missing_ids == [70_003, 70_005]
      assert partial_ids == [70_002]
      assert complete_ids == [70_001, 70_004]
    end

    test "treats count of 0 as missing (not partial)" do
      set = TestFactory.build_set(%{id: 1, code: "TST"})
      c1 = card(80_001, "common", set.id)

      holdings = [holding(c1, 0)]

      result = SetCompletion.from(set, [c1], holdings)

      assert Enum.map(result.buckets.missing, & &1.arena_id) == [80_001]
      assert result.buckets.partial == []
      assert result.buckets.complete == []
    end

    test "groups counts by rarity with full totals" do
      set = TestFactory.build_set(%{id: 1, code: "TST"})

      cards = [
        card(81_001, "mythic", set.id),
        card(81_002, "mythic", set.id),
        card(81_003, "rare", set.id),
        card(81_004, "rare", set.id),
        card(81_005, "rare", set.id),
        card(81_006, "uncommon", set.id),
        card(81_007, "common", set.id),
        card(81_008, "common", set.id)
      ]

      holdings = [
        holding(Enum.at(cards, 0), 4),
        holding(Enum.at(cards, 2), 2),
        holding(Enum.at(cards, 3), 4),
        holding(Enum.at(cards, 5), 1),
        holding(Enum.at(cards, 6), 4)
      ]

      %{by_rarity: rows} = SetCompletion.from(set, cards, holdings)

      assert rows["mythic"] == %{missing: 1, partial: 0, complete: 1, total: 2}
      assert rows["rare"] == %{missing: 1, partial: 1, complete: 1, total: 3}
      assert rows["uncommon"] == %{missing: 0, partial: 1, complete: 0, total: 1}
      assert rows["common"] == %{missing: 1, partial: 0, complete: 1, total: 2}
    end

    test "ignores holdings whose card belongs to a different set" do
      target = TestFactory.build_set(%{id: 1, code: "TGT"})
      other = TestFactory.build_set(%{id: 2, code: "OTH"})

      target_card = card(82_001, "common", target.id)
      stray_card = card(82_002, "common", other.id)

      holdings = [
        holding(target_card, 4),
        holding(stray_card, 2)
      ]

      result = SetCompletion.from(target, [target_card], holdings)

      assert result.buckets.complete |> Enum.map(& &1.arena_id) == [82_001]
      assert result.buckets.partial == []
      refute Enum.any?(result.buckets.missing, &(&1.arena_id == 82_002))
    end

    test "with empty holdings, every card is missing" do
      set = TestFactory.build_set(%{id: 1, code: "EMPTY"})
      c1 = card(83_001, "common", set.id)
      r1 = card(83_002, "rare", set.id)

      result = SetCompletion.from(set, [c1, r1], [])

      assert Enum.map(result.buckets.missing, & &1.arena_id) |> Enum.sort() == [83_001, 83_002]
      assert result.buckets.partial == []
      assert result.buckets.complete == []
      assert result.by_rarity["common"] == %{missing: 1, partial: 0, complete: 0, total: 1}
      assert result.by_rarity["rare"] == %{missing: 1, partial: 0, complete: 0, total: 1}
    end

    test "with empty set_cards, all buckets are empty" do
      set = TestFactory.build_set(%{id: 1, code: "NONE"})

      result = SetCompletion.from(set, [], [])

      assert result.set == set
      assert result.buckets.missing == []
      assert result.buckets.partial == []
      assert result.buckets.complete == []
      assert result.by_rarity == %{}
    end

    test "preserves the set struct on the result" do
      set = TestFactory.build_set(%{id: 7, code: "PRE", name: "Preserve"})

      result = SetCompletion.from(set, [], [])

      assert result.set == set
    end

    test "missing cards retain their full %Card{} so the gap list can render them" do
      set = TestFactory.build_set(%{id: 1, code: "FULL"})
      c1 = card(84_001, "common", set.id)

      result = SetCompletion.from(set, [c1], [])

      [missing] = result.buckets.missing
      assert missing.arena_id == 84_001
      assert missing.name == c1.name
      assert missing.rarity == "common"
    end
  end

  describe "totals/1" do
    test "returns the per-bucket totals across all rarities" do
      set = TestFactory.build_set(%{id: 1, code: "TOT"})

      cards = [
        card(85_001, "mythic", set.id),
        card(85_002, "rare", set.id),
        card(85_003, "rare", set.id),
        card(85_004, "common", set.id)
      ]

      holdings = [
        holding(Enum.at(cards, 0), 4),
        holding(Enum.at(cards, 1), 2)
      ]

      result = SetCompletion.from(set, cards, holdings)

      assert SetCompletion.totals(result) == %{
               missing: 2,
               partial: 1,
               complete: 1,
               total: 4
             }
    end
  end
end
