defmodule Scry2.Collection.HoldingTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Holding
  alias Scry2.Collection.Snapshot
  alias Scry2.TestFactory

  defp snapshot(entries) do
    %Snapshot{cards_json: Snapshot.encode_entries(entries)}
  end

  defp cards_by_arena_id(cards) do
    Map.new(cards, &{&1.arena_id, &1})
  end

  describe "from_snapshot/2" do
    test "hydrates each entry with the matching card" do
      lightning_bolt =
        TestFactory.build_card(%{arena_id: 70_001, name: "Lightning Bolt", rarity: "common"})

      shock = TestFactory.build_card(%{arena_id: 70_002, name: "Shock", rarity: "common"})

      snapshot = snapshot([{70_001, 4}, {70_002, 1}])
      holdings = Holding.from_snapshot(snapshot, cards_by_arena_id([lightning_bolt, shock]))

      assert length(holdings) == 2
      bolt_holding = Enum.find(holdings, &(&1.arena_id == 70_001))
      assert bolt_holding.count == 4
      assert bolt_holding.card.name == "Lightning Bolt"
      assert bolt_holding.copies_to_playset == 0

      shock_holding = Enum.find(holdings, &(&1.arena_id == 70_002))
      assert shock_holding.count == 1
      assert shock_holding.copies_to_playset == 3
    end

    test "drops entries whose card has not yet been synthesised" do
      known = TestFactory.build_card(%{arena_id: 70_010})

      snapshot = snapshot([{70_010, 2}, {99_999, 1}])
      holdings = Holding.from_snapshot(snapshot, cards_by_arena_id([known]))

      assert [%Holding{arena_id: 70_010}] = holdings
    end

    test "returns [] for nil snapshot" do
      assert Holding.from_snapshot(nil, %{}) == []
    end

    test "returns [] for snapshot with no entries" do
      assert Holding.from_snapshot(snapshot([]), %{}) == []
    end

    test "clamps copies_to_playset at zero when count exceeds 4" do
      card = TestFactory.build_card(%{arena_id: 70_020})
      snapshot = snapshot([{70_020, 7}])

      [holding] = Holding.from_snapshot(snapshot, cards_by_arena_id([card]))
      assert holding.copies_to_playset == 0
    end
  end
end
