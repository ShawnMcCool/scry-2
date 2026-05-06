defmodule Scry2Web.Components.MasteryCard.HelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.MasteryCard.Helpers, as: H

  describe "xp_progress_percent/1" do
    test "0 xp → 0.0%" do
      assert H.xp_progress_percent(0) == 0.0
    end

    test "500/1000 → 50.0%" do
      assert H.xp_progress_percent(500) == 50.0
    end

    test "999/1000 → 99.9%" do
      assert H.xp_progress_percent(999) == 99.9
    end

    test "clamps over-range to 100.0%" do
      assert H.xp_progress_percent(1500) == 100.0
    end

    test "nil → 0.0%" do
      assert H.xp_progress_percent(nil) == 0.0
    end

    test "negative xp clamps to 0.0%" do
      assert H.xp_progress_percent(-50) == 0.0
    end
  end

  describe "format_tier/1" do
    test "renders integer as 'Tier N'" do
      assert H.format_tier(12) == "Tier 12"
    end

    test "nil renders em dash" do
      assert H.format_tier(nil) == "—"
    end
  end

  describe "season_end_countdown/2" do
    test "nil ends_at returns empty string" do
      assert H.season_end_countdown(nil, ~U[2026-05-03 00:00:00Z]) == ""
    end

    test "less than a day returns 'Ends today'" do
      ends = ~U[2026-05-03 18:00:00Z]
      now = ~U[2026-05-03 12:00:00Z]
      assert H.season_end_countdown(ends, now) == "Ends today"
    end

    test "between 1.0 and 1.5 days returns 'Ends tomorrow'" do
      ends = ~U[2026-05-04 12:00:00Z]
      now = ~U[2026-05-03 06:00:00Z]
      assert H.season_end_countdown(ends, now) == "Ends tomorrow"
    end

    test "more days returns 'Ends in N days'" do
      ends = ~U[2026-05-15 00:00:00Z]
      now = ~U[2026-05-03 00:00:00Z]
      assert H.season_end_countdown(ends, now) == "Ends in 12 days"
    end

    test "past returns 'Season ended'" do
      ends = ~U[2026-05-01 00:00:00Z]
      now = ~U[2026-05-03 00:00:00Z]
      assert H.season_end_countdown(ends, now) == "Season ended"
    end
  end

  describe "set_code_from_season_name/1" do
    test "BattlePass_SOS → 'SOS'" do
      assert H.set_code_from_season_name("BattlePass_SOS") == "SOS"
    end

    test "lowercase suffix is upcased" do
      assert H.set_code_from_season_name("BattlePass_dft") == "DFT"
    end

    test "nil → nil" do
      assert H.set_code_from_season_name(nil) == nil
    end

    test "non-matching shape → nil" do
      assert H.set_code_from_season_name("MasterySeason_2026Q2") == nil
    end

    test "empty suffix → nil" do
      assert H.set_code_from_season_name("BattlePass_") == nil
    end
  end

  describe "xp_per_tier/0" do
    test "xp_per_tier returns 1000" do
      assert H.xp_per_tier() == 1_000
    end
  end

  describe "summary_line/3" do
    test "drops countdown when nil" do
      assert H.summary_line(12, nil, ~U[2026-05-03 00:00:00Z]) == "Tier 12"
    end

    test "joins tier and countdown with mid-dot" do
      ends = ~U[2026-05-15 00:00:00Z]
      now = ~U[2026-05-03 00:00:00Z]
      assert H.summary_line(12, ends, now) == "Tier 12 · Ends in 12 days"
    end

    test "nil tier still emits em dash" do
      assert H.summary_line(nil, nil, ~U[2026-05-03 00:00:00Z]) == "—"
    end
  end

  describe "forecast_label/1" do
    test "renders rate and projected tier for a successful forecast" do
      forecast = %{
        xp_per_day: 714.285,
        projected_tier_at_season_end: 56,
        days_to_next_tier: 1.4,
        season_ends_at: ~U[2026-06-01 00:00:00Z]
      }

      assert H.forecast_label(forecast) ==
               "+714 XP/day · projected Tier 56 by season end"
    end

    test "rounds rate to whole XP" do
      forecast = %{
        xp_per_day: 999.6,
        projected_tier_at_season_end: 70,
        days_to_next_tier: 1.0,
        season_ends_at: ~U[2026-06-01 00:00:00Z]
      }

      assert H.forecast_label(forecast) ==
               "+1,000 XP/day · projected Tier 70 by season end"
    end

    test "non-numeric variants render empty string" do
      assert H.forecast_label(:insufficient_data) == ""
      assert H.forecast_label(:no_progress) == ""
      assert H.forecast_label(:season_ended) == ""
      assert H.forecast_label(:no_season_end) == ""
      assert H.forecast_label(nil) == ""
    end
  end
end
