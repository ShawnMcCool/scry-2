defmodule Scry2.Insights.Detectors.CraftingVelocityTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.CraftingVelocity
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  defp insert_craft!(rarity, quantity, days_ago \\ 1) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    occurred = DateTime.add(now, -days_ago, :day)
    snapshot = TestFactory.create_collection_snapshot(%{snapshot_ts: occurred})

    TestFactory.create_craft(%{
      arena_id: System.unique_integer([:positive]),
      rarity: rarity,
      quantity: quantity,
      occurred_at_lower: occurred,
      occurred_at_upper: occurred,
      to_snapshot_id: snapshot.id
    })
  end

  describe "tier/0" do
    test "is tier 1" do
      assert CraftingVelocity.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil when no crafts" do
      assert CraftingVelocity.detect([]) == nil
    end

    test "returns nil when crafts below threshold" do
      insert_craft!("rare", 1)
      insert_craft!("rare", 1)
      assert CraftingVelocity.detect([]) == nil
    end

    test "ignores crafts outside the lookback window" do
      insert_craft!("rare", 1, 30)
      insert_craft!("rare", 1, 30)
      insert_craft!("rare", 1, 30)
      assert CraftingVelocity.detect([]) == nil
    end

    test "returns insight when total meets threshold" do
      insert_craft!("mythic", 1)
      insert_craft!("rare", 2)
      insert_craft!("uncommon", 1)
      # Total = 4

      assert %Insight{} = insight = CraftingVelocity.detect([])
      assert insight.detector == "CraftingVelocity"
      assert insight.measurements["total"] == 4
      assert insight.measurements["mythics"] == 1
      assert insight.measurements["rares"] == 2
      assert insight.measurements["uncommons"] == 1
    end
  end
end
