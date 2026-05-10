defmodule Scry2.Insights.Detectors.MulliganOutcomeTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.MulliganOutcome
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 1" do
      assert MulliganOutcome.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil with no data" do
      assert MulliganOutcome.detect([]) == nil
    end

    test "returns nil below the minimum sample size" do
      for _ <- 1..10, do: TestFactory.create_match(%{total_mulligans: 0, won: true})
      assert MulliganOutcome.detect([]) == nil
    end

    test "returns nil when only one bucket has data" do
      for _ <- 1..30, do: TestFactory.create_match(%{total_mulligans: 0, won: true})
      assert MulliganOutcome.detect([]) == nil
    end

    test "returns nil when the gap is too small" do
      # 50% kept, 48% mulled — 2pt gap, below threshold.
      for _ <- 1..10, do: TestFactory.create_match(%{total_mulligans: 0, won: true})
      for _ <- 1..10, do: TestFactory.create_match(%{total_mulligans: 0, won: false})
      for _ <- 1..12, do: TestFactory.create_match(%{total_mulligans: 1, won: true})
      for _ <- 1..13, do: TestFactory.create_match(%{total_mulligans: 1, won: false})

      assert MulliganOutcome.detect([]) == nil
    end

    test "returns insight with measurements when both buckets have data and gap is large" do
      # 20 kept hands: 14 wins (70% WR)
      for _ <- 1..14, do: TestFactory.create_match(%{total_mulligans: 0, won: true})
      for _ <- 1..6, do: TestFactory.create_match(%{total_mulligans: 0, won: false})
      # 20 mulled hands: 6 wins (30% WR)
      for _ <- 1..6, do: TestFactory.create_match(%{total_mulligans: 1, won: true})
      for _ <- 1..14, do: TestFactory.create_match(%{total_mulligans: 1, won: false})

      assert %Insight{} = insight = MulliganOutcome.detect([])
      assert insight.detector == "MulliganOutcome"
      assert insight.tier == 1
      assert insight.sample_size == 40
      assert_in_delta insight.measurements["kept_wr"], 0.70, 0.01
      assert_in_delta insight.measurements["mull_wr"], 0.30, 0.01
      assert_in_delta insight.measurements["gap"], 0.40, 0.01
    end
  end
end
