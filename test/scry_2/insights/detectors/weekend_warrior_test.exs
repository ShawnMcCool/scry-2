defmodule Scry2.Insights.Detectors.WeekendWarriorTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.WeekendWarrior
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  # 2026-05-09 is a Saturday, 2026-05-10 is a Sunday.
  # 2026-05-04 through 2026-05-08 are Monday through Friday.
  defp at(date, hour \\ 12) do
    DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp matches_on_weekend(count) do
    Enum.each(1..count, fn _ ->
      TestFactory.create_match(%{
        won: true,
        started_at: at(~D[2026-05-09], 12)
      })
    end)
  end

  defp matches_on_weekday(count) do
    Enum.each(1..count, fn _ ->
      TestFactory.create_match(%{
        won: true,
        started_at: at(~D[2026-05-06], 12)
      })
    end)
  end

  describe "tier/0" do
    test "is tier 1" do
      assert WeekendWarrior.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil with no matches" do
      assert WeekendWarrior.detect([]) == nil
    end

    test "returns nil when total matches below threshold" do
      matches_on_weekend(20)
      matches_on_weekday(10)
      # 30 < 50 minimum
      assert WeekendWarrior.detect([]) == nil
    end

    test "returns nil when weekend share is near the uniform baseline" do
      # 30% weekend share with ~50 matches — too close to baseline (28.6%).
      matches_on_weekend(15)
      matches_on_weekday(35)
      assert WeekendWarrior.detect([]) == nil
    end

    test "fires above the high threshold (weekend-heavy)" do
      matches_on_weekend(40)
      matches_on_weekday(15)
      # 40/55 ≈ 72.7% weekend

      assert %Insight{} = insight = WeekendWarrior.detect([])
      assert insight.detector == "WeekendWarrior"
      assert insight.tier == 1
      assert insight.measurements["direction"] == "weekend"
      assert insight.measurements["weekend_n"] == 40
      assert insight.measurements["weekday_n"] == 15
      assert insight.measurements["total_n"] == 55
      assert_in_delta insight.measurements["weekend_share"], 40 / 55, 0.001
    end

    test "fires below the low threshold (weeknight-heavy)" do
      matches_on_weekend(5)
      matches_on_weekday(50)
      # 5/55 ≈ 9.1% weekend → weeknight grinder

      assert %Insight{} = insight = WeekendWarrior.detect([])
      assert insight.measurements["direction"] == "weeknight"
      assert insight.measurements["weekend_n"] == 5
      assert insight.measurements["weekday_n"] == 50
    end

    test "ignores matches with nil started_at or nil won" do
      # 30 valid weekend matches + noise that should not count.
      matches_on_weekend(45)
      matches_on_weekday(10)

      for _ <- 1..50 do
        TestFactory.create_match(%{won: nil, started_at: at(~D[2026-05-09])})
      end

      for _ <- 1..50 do
        TestFactory.create_match(%{won: true, started_at: nil})
      end

      assert %Insight{} = insight = WeekendWarrior.detect([])
      assert insight.measurements["total_n"] == 55
    end

    test "fills stats payload for tile rendering" do
      matches_on_weekend(40)
      matches_on_weekday(15)

      assert %Insight{stats: stats} = WeekendWarrior.detect([])
      assert stats["primary"]["lbl"] == "weekend"
      assert stats["secondary"]["num"] == "n=55"
      assert stats["secondary"]["lbl"] == "matches"
    end
  end
end
