defmodule Scry2.Insights.Detectors.OnPlayVsOnDrawTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.OnPlayVsOnDraw
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  describe "tier/0" do
    test "is tier 1" do
      assert OnPlayVsOnDraw.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil when no matches" do
      assert OnPlayVsOnDraw.detect([]) == nil
    end

    test "returns nil when fewer than the minimum sample size" do
      for _ <- 1..10 do
        TestFactory.create_match(%{on_play: true, won: true})
      end

      assert OnPlayVsOnDraw.detect([]) == nil
    end

    test "ignores matches with nil on_play" do
      for _ <- 1..40 do
        TestFactory.create_match(%{on_play: nil, won: true})
      end

      assert OnPlayVsOnDraw.detect([]) == nil
    end

    test "returns an Insight with correct measurements when threshold met" do
      # 20 on play: 12 wins, 8 losses → 60% WR
      for _ <- 1..12, do: TestFactory.create_match(%{on_play: true, won: true})
      for _ <- 1..8, do: TestFactory.create_match(%{on_play: true, won: false})
      # 15 on draw: 6 wins, 9 losses → 40% WR
      for _ <- 1..6, do: TestFactory.create_match(%{on_play: false, won: true})
      for _ <- 1..9, do: TestFactory.create_match(%{on_play: false, won: false})

      insight = OnPlayVsOnDraw.detect([])

      assert %Insight{} = insight
      assert insight.detector == "OnPlayVsOnDraw"
      assert insight.surface == "home"
      assert insight.tier == 1
      assert insight.sample_size == 35
      assert insight.title_template == "on_play_vs_on_draw.title"
      assert insight.body_template == "on_play_vs_on_draw.body"

      m = insight.measurements
      assert m["on_play_n"] == 20
      assert m["on_draw_n"] == 15
      assert m["total_n"] == 35
      assert_in_delta m["on_play_wr"], 0.6, 0.001
      assert_in_delta m["on_draw_wr"], 0.4, 0.001
      assert_in_delta m["gap"], 0.2, 0.001

      stats = insight.stats
      assert stats["primary"]["num"] == "60%"
      assert stats["secondary"]["num"] == "40%"
      assert stats["tertiary"]["num"] == "35"
    end
  end
end
