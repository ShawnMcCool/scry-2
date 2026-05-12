defmodule Scry2.Insights.Detectors.DraftConversionRateTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.DraftConversionRate
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  defp create_completed_draft!(wins, losses, days_ago \\ 1) do
    now = DateTime.utc_now(:second)
    completed = DateTime.add(now, -days_ago, :day)
    started = DateTime.add(completed, -2, :hour)

    TestFactory.create_draft(%{
      started_at: started,
      completed_at: completed,
      wins: wins,
      losses: losses
    })
  end

  describe "tier/0" do
    test "is tier 1" do
      assert DraftConversionRate.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil when there are no completed drafts" do
      assert DraftConversionRate.detect([]) == nil
    end

    test "returns nil when there are fewer than 5 completed drafts" do
      for _ <- 1..4, do: create_completed_draft!(4, 2)
      assert DraftConversionRate.detect([]) == nil
    end

    test "ignores drafts that are still in progress" do
      for _ <- 1..6 do
        TestFactory.create_draft(%{
          started_at: DateTime.utc_now(:second),
          completed_at: nil,
          wins: nil,
          losses: nil
        })
      end

      assert DraftConversionRate.detect([]) == nil
    end

    test "returns insight when 5+ completed drafts are present" do
      for _ <- 1..5, do: create_completed_draft!(4, 2)

      assert %Insight{} = insight = DraftConversionRate.detect([])
      assert insight.detector == "DraftConversionRate"
      assert insight.tier == 1
      assert_in_delta insight.measurements["avg_wins"], 4.0, 0.01
      assert insight.measurements["drafts_n"] == 5
    end

    test "counts trophies (7 wins) in the lookback window" do
      create_completed_draft!(7, 0, 1)
      create_completed_draft!(7, 1, 2)
      create_completed_draft!(3, 3, 3)
      create_completed_draft!(2, 3, 4)
      create_completed_draft!(5, 3, 5)

      assert %Insight{} = insight = DraftConversionRate.detect([])
      assert insight.measurements["trophies"] == 2
    end

    test "only uses the most recent 10 completed drafts (rolling window)" do
      # 5 old high-win drafts (would skew average up) — must be excluded.
      for n <- 1..5, do: create_completed_draft!(7, 1, 30 + n)
      # 10 recent low-win drafts.
      for n <- 1..10, do: create_completed_draft!(2, 3, n)

      assert %Insight{} = insight = DraftConversionRate.detect([])
      assert insight.measurements["drafts_n"] == 10
      assert_in_delta insight.measurements["avg_wins"], 2.0, 0.01
    end

    test "fills stats payload for tile rendering" do
      create_completed_draft!(7, 0, 1)
      create_completed_draft!(5, 3, 2)
      create_completed_draft!(4, 3, 3)
      create_completed_draft!(3, 3, 4)
      create_completed_draft!(2, 3, 5)

      assert %Insight{stats: stats} = DraftConversionRate.detect([])
      assert stats["primary"]["lbl"] == "avg wins"
      assert stats["secondary"]["lbl"] == "trophies"
      assert stats["tertiary"]["num"] == "n=5"
      assert stats["tertiary"]["lbl"] == "drafts"
    end
  end
end
