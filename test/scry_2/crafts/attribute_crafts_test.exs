defmodule Scry2.Crafts.AttributeCraftsTest do
  use ExUnit.Case, async: true

  alias Scry2.Crafts.{AttributeCrafts, Attribution}

  import Scry2.TestFactory

  # Helper: build a snapshot with explicit wildcard counts and entries.
  defp snap(opts) do
    build_collection_snapshot(
      reader_confidence: "walker",
      entries: Keyword.get(opts, :entries, []),
      wildcards_common: Keyword.get(opts, :common, 0),
      wildcards_uncommon: Keyword.get(opts, :uncommon, 0),
      wildcards_rare: Keyword.get(opts, :rare, 0),
      wildcards_mythic: Keyword.get(opts, :mythic, 0)
    )
  end

  describe "attribute/3" do
    test "returns [] when prev is nil (baseline)" do
      next = snap(rare: 4, entries: [{1, 1}])
      assert AttributeCrafts.attribute(nil, next, %{}) == []
    end

    test "returns [] when prev has nil wildcard fields (scanner fallback)" do
      prev =
        build_collection_snapshot(
          reader_confidence: "fallback_scan",
          entries: [{1, 0}],
          wildcards_rare: nil
        )

      next = snap(rare: 3, entries: [{1, 1}])
      assert AttributeCrafts.attribute(prev, next, %{1 => :rare}) == []
    end

    test "returns [] when next has nil wildcard fields (scanner fallback)" do
      prev = snap(rare: 4, entries: [{1, 0}])

      next =
        build_collection_snapshot(
          reader_confidence: "fallback_scan",
          entries: [{1, 1}],
          wildcards_rare: nil
        )

      assert AttributeCrafts.attribute(prev, next, %{1 => :rare}) == []
    end

    test "returns [] when nothing changed" do
      prev = snap(rare: 4, entries: [{1, 1}])
      next = snap(rare: 4, entries: [{1, 1}])
      assert AttributeCrafts.attribute(prev, next, %{}) == []
    end

    test "single rare craft: rare WC -1, exactly one rare card +1" do
      prev = snap(rare: 4, entries: [{42, 0}])
      next = snap(rare: 3, entries: [{42, 1}])

      result = AttributeCrafts.attribute(prev, next, %{42 => :rare})
      assert result == [%Attribution{arena_id: 42, rarity: :rare, quantity: 1}]
    end

    test "single mythic craft: mythic WC -2, one mythic card +2" do
      prev = snap(mythic: 5, entries: [{99, 0}])
      next = snap(mythic: 3, entries: [{99, 2}])

      result = AttributeCrafts.attribute(prev, next, %{99 => :mythic})
      assert result == [%Attribution{arena_id: 99, rarity: :mythic, quantity: 2}]
    end

    test "multi-rarity simultaneous: rare and uncommon crafted same window" do
      prev = snap(rare: 4, uncommon: 6, entries: [{1, 0}, {2, 0}])
      next = snap(rare: 3, uncommon: 5, entries: [{1, 1}, {2, 1}])

      rarities = %{1 => :rare, 2 => :uncommon}
      result = AttributeCrafts.attribute(prev, next, rarities)

      assert Enum.sort_by(result, & &1.arena_id) == [
               %Attribution{arena_id: 1, rarity: :rare, quantity: 1},
               %Attribution{arena_id: 2, rarity: :uncommon, quantity: 1}
             ]
    end

    test "contested window: two mythic cards gained when one mythic spent → skip" do
      prev = snap(mythic: 2, entries: [{1, 0}, {2, 0}])
      next = snap(mythic: 1, entries: [{1, 1}, {2, 1}])

      rarities = %{1 => :mythic, 2 => :mythic}
      assert AttributeCrafts.attribute(prev, next, rarities) == []
    end

    test "vault payout (rarity went up) is ignored" do
      prev = snap(rare: 3)
      next = snap(rare: 4)
      assert AttributeCrafts.attribute(prev, next, %{}) == []
    end

    test "pack opening: cards gained but no wildcard decrease → []" do
      prev = snap(rare: 4, entries: [{1, 0}, {2, 0}])
      next = snap(rare: 4, entries: [{1, 1}, {2, 2}])

      rarities = %{1 => :rare, 2 => :common}
      assert AttributeCrafts.attribute(prev, next, rarities) == []
    end

    test "wildcard down but no card gained → []" do
      prev = snap(rare: 4, entries: [{1, 1}])
      next = snap(rare: 3, entries: [{1, 1}])
      assert AttributeCrafts.attribute(prev, next, %{}) == []
    end

    test "wildcard down + card of wrong rarity gained → []" do
      prev = snap(rare: 4, entries: [{1, 0}])
      next = snap(rare: 3, entries: [{1, 1}])

      rarities = %{1 => :uncommon}
      assert AttributeCrafts.attribute(prev, next, rarities) == []
    end

    test "wildcard down by 1 + matching card gained 2 (qty mismatch) → []" do
      prev = snap(rare: 4, entries: [{1, 0}])
      next = snap(rare: 3, entries: [{1, 2}])

      rarities = %{1 => :rare}
      assert AttributeCrafts.attribute(prev, next, rarities) == []
    end

    test "wildcard down + matching card gained, plus an unrelated card of different rarity gained → still attributes" do
      # Pack opening of an uncommon happened in the same window as a rare craft.
      # The rare-side signal is clean: rare WC -1, one rare card +1.
      prev = snap(rare: 4, uncommon: 6, entries: [{1, 0}, {2, 0}])
      next = snap(rare: 3, uncommon: 6, entries: [{1, 1}, {2, 1}])

      rarities = %{1 => :rare, 2 => :uncommon}
      result = AttributeCrafts.attribute(prev, next, rarities)

      assert result == [%Attribution{arena_id: 1, rarity: :rare, quantity: 1}]
    end

    test "rarity not in lookup map → skip that arena_id (treats as unknown rarity)" do
      prev = snap(rare: 4, entries: [{1, 0}])
      next = snap(rare: 3, entries: [{1, 1}])

      assert AttributeCrafts.attribute(prev, next, %{}) == []
    end

    test "ignores cards whose count decreased" do
      # Removed cards (vault contributions) are not crafts.
      prev = snap(rare: 4, entries: [{1, 4}])
      next = snap(rare: 3, entries: [{1, 3}])

      rarities = %{1 => :rare}
      assert AttributeCrafts.attribute(prev, next, rarities) == []
    end
  end
end
