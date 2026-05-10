defmodule Scry2.Insights.Detectors.DeckColorOutlierTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.DeckColorOutlier
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 2" do
      assert DeckColorOutlier.tier() == 2
    end
  end

  describe "detect/1" do
    test "returns nil when baseline below minimum" do
      for _ <- 1..10 do
        TestFactory.create_match(%{deck_colors: "WU", won: true})
      end

      assert DeckColorOutlier.detect([]) == nil
    end

    test "returns nil when no combo has enough matches" do
      for _ <- 1..50 do
        TestFactory.create_match(%{
          deck_colors: "color-#{System.unique_integer([:positive])}",
          won: true
        })
      end

      assert DeckColorOutlier.detect([]) == nil
    end

    test "returns insight for a color combo whose WR significantly beats baseline" do
      # Baseline: 50 matches at ~50% WR with various colors
      for _ <- 1..25, do: TestFactory.create_match(%{deck_colors: "BR", won: true})
      for _ <- 1..25, do: TestFactory.create_match(%{deck_colors: "BR", won: false})

      # Outlier: 14-1 with WUR
      for _ <- 1..14, do: TestFactory.create_match(%{deck_colors: "WUR", won: true})
      for _ <- 1..1, do: TestFactory.create_match(%{deck_colors: "WUR", won: false})

      assert %Insight{} = insight = DeckColorOutlier.detect([])
      assert insight.tier == 2
      assert insight.measurements["colors"] == "WUR"
      assert insight.measurements["combo_n"] == 15
      assert insight.measurements["direction"] == "above"
      assert insight.confidence < 0.05
    end
  end
end
