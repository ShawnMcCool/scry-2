defmodule Scry2.Insights.Detectors.BO1VsBO3GapTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.BO1VsBO3Gap
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 1" do
      assert BO1VsBO3Gap.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil with no data" do
      assert BO1VsBO3Gap.detect([]) == nil
    end

    test "returns nil when one bucket is below threshold" do
      for _ <- 1..20, do: TestFactory.create_match(%{format_type: "Constructed", won: true})
      for _ <- 1..5, do: TestFactory.create_match(%{format_type: "Traditional", won: true})
      assert BO1VsBO3Gap.detect([]) == nil
    end

    test "returns nil when both buckets exist but gap is small" do
      for _ <- 1..20, do: TestFactory.create_match(%{format_type: "Constructed", won: true})
      for _ <- 1..20, do: TestFactory.create_match(%{format_type: "Constructed", won: false})
      for _ <- 1..20, do: TestFactory.create_match(%{format_type: "Traditional", won: true})
      for _ <- 1..20, do: TestFactory.create_match(%{format_type: "Traditional", won: false})

      assert BO1VsBO3Gap.detect([]) == nil
    end

    test "returns insight with measurements when both buckets have a meaningful gap" do
      # BO1 (Constructed): 20 played, 14 wins (70%)
      for _ <- 1..14, do: TestFactory.create_match(%{format_type: "Constructed", won: true})
      for _ <- 1..6, do: TestFactory.create_match(%{format_type: "Constructed", won: false})
      # BO1 (Limited): 10 played, 5 wins (50%)
      for _ <- 1..5, do: TestFactory.create_match(%{format_type: "Limited", won: true})
      for _ <- 1..5, do: TestFactory.create_match(%{format_type: "Limited", won: false})
      # BO3 (Traditional): 20 played, 8 wins (40%)
      for _ <- 1..8, do: TestFactory.create_match(%{format_type: "Traditional", won: true})
      for _ <- 1..12, do: TestFactory.create_match(%{format_type: "Traditional", won: false})

      assert %Insight{} = insight = BO1VsBO3Gap.detect([])
      m = insight.measurements
      assert m["bo1_n"] == 30
      assert m["bo3_n"] == 20
      assert_in_delta m["bo1_wr"], 19 / 30, 0.001
      assert_in_delta m["bo3_wr"], 0.40, 0.001
      assert m["total_n"] == 50
    end
  end
end
