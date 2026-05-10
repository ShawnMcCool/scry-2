defmodule Scry2.Insights.Detectors.FormatBaselineTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.FormatBaseline
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 1" do
      assert FormatBaseline.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil with no data" do
      assert FormatBaseline.detect([]) == nil
    end

    test "returns nil when no format meets the per-format minimum" do
      for _ <- 1..10, do: TestFactory.create_match(%{format_type: "Constructed", won: true})
      for _ <- 1..10, do: TestFactory.create_match(%{format_type: "Limited", won: false})
      assert FormatBaseline.detect([]) == nil
    end

    test "returns insight identifying the highest-WR format" do
      # Constructed: 20 played, 16 wins (80% WR) — best
      for _ <- 1..16, do: TestFactory.create_match(%{format_type: "Constructed", won: true})
      for _ <- 1..4, do: TestFactory.create_match(%{format_type: "Constructed", won: false})
      # Limited: 25 played, 10 wins (40% WR)
      for _ <- 1..10, do: TestFactory.create_match(%{format_type: "Limited", won: true})
      for _ <- 1..15, do: TestFactory.create_match(%{format_type: "Limited", won: false})

      assert %Insight{} = insight = FormatBaseline.detect([])
      assert insight.measurements["best_format"] == "Constructed"
      assert_in_delta insight.measurements["best_wr"], 0.80, 0.001
      assert insight.measurements["best_n"] == 20
      assert insight.measurements["format_count"] == 2
    end
  end
end
