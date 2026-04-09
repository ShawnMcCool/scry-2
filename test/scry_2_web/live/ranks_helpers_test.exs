defmodule Scry2Web.RanksHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.RanksHelpers

  describe "format_rank/2" do
    test "formats class and level" do
      assert RanksHelpers.format_rank("Gold", 1) == "Gold 1"
    end

    test "returns class alone when level is nil" do
      assert RanksHelpers.format_rank("Mythic", nil) == "Mythic"
    end

    test "returns dash for nil class" do
      assert RanksHelpers.format_rank(nil, 1) == "—"
    end
  end

  describe "format_record/2" do
    test "formats W-L record" do
      assert RanksHelpers.format_record(10, 5) == "10–5"
    end

    test "returns dash for nil values" do
      assert RanksHelpers.format_record(nil, 5) == "—"
      assert RanksHelpers.format_record(10, nil) == "—"
    end
  end

  describe "step_pips/1" do
    test "returns filled and total pips" do
      assert RanksHelpers.step_pips(3) == {3, 6}
    end

    test "returns zero filled for nil" do
      assert RanksHelpers.step_pips(nil) == {0, 6}
    end
  end

  describe "rank_score/3" do
    test "Bronze 4 step 0 is 0 (bottom of scale)" do
      assert RanksHelpers.rank_score("Bronze", 4, 0) == 0
    end

    test "Bronze 4 step 5 is 5" do
      assert RanksHelpers.rank_score("Bronze", 4, 5) == 5
    end

    test "Bronze 3 step 0 is 6" do
      assert RanksHelpers.rank_score("Bronze", 3, 0) == 6
    end

    test "Bronze 1 step 5 is 23 (top of Bronze)" do
      assert RanksHelpers.rank_score("Bronze", 1, 5) == 23
    end

    test "Silver 4 step 0 is 24 (bottom of Silver)" do
      assert RanksHelpers.rank_score("Silver", 4, 0) == 24
    end

    test "Gold 4 step 0 is 48" do
      assert RanksHelpers.rank_score("Gold", 4, 0) == 48
    end

    test "Platinum 4 step 0 is 72" do
      assert RanksHelpers.rank_score("Platinum", 4, 0) == 72
    end

    test "Diamond 4 step 0 is 96" do
      assert RanksHelpers.rank_score("Diamond", 4, 0) == 96
    end

    test "Mythic is always 120 regardless of level and step" do
      assert RanksHelpers.rank_score("Mythic", nil, nil) == 120
      assert RanksHelpers.rank_score("Mythic", 1, 3) == 120
    end

    test "nil class returns 0" do
      assert RanksHelpers.rank_score(nil, nil, nil) == 0
    end

    test "Beginner maps to Bronze" do
      assert RanksHelpers.rank_score("Beginner", 4, 0) == RanksHelpers.rank_score("Bronze", 4, 0)
    end
  end

  describe "rank_axis_ticks/0" do
    test "returns tick entries for all six rank classes" do
      ticks = RanksHelpers.rank_axis_ticks()
      labels = Enum.map(ticks, fn {_score, label} -> label end)
      assert labels == ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "Mythic"]
    end

    test "Bronze tick is at 0, Mythic tick is at 120" do
      ticks = RanksHelpers.rank_axis_ticks()
      assert {0, "Bronze"} in ticks
      assert {120, "Mythic"} in ticks
    end
  end

  describe "climb_series/2" do
    test "returns [[iso8601, score]] pairs in snapshot order for :constructed" do
      snapshots = [
        %{
          occurred_at: ~U[2026-01-01 00:00:00Z],
          constructed_class: "Bronze",
          constructed_level: 4,
          constructed_step: 0,
          limited_class: "Bronze",
          limited_level: 4,
          limited_step: 0
        },
        %{
          occurred_at: ~U[2026-01-02 00:00:00Z],
          constructed_class: "Silver",
          constructed_level: 4,
          constructed_step: 2,
          limited_class: "Bronze",
          limited_level: 4,
          limited_step: 3
        }
      ]

      series = RanksHelpers.climb_series(snapshots, :constructed)

      assert length(series) == 2
      [[ts1, score1], [ts2, score2]] = series
      assert score1 == RanksHelpers.rank_score("Bronze", 4, 0)
      assert score2 == RanksHelpers.rank_score("Silver", 4, 2)
      assert String.contains?(ts1, "2026-01-01")
      assert String.contains?(ts2, "2026-01-02")
    end

    test "returns [[iso8601, score]] pairs for :limited" do
      snapshots = [
        %{
          occurred_at: ~U[2026-01-01 00:00:00Z],
          constructed_class: "Gold",
          constructed_level: 2,
          constructed_step: 3,
          limited_class: "Platinum",
          limited_level: 1,
          limited_step: 5
        }
      ]

      [[_ts, score]] = RanksHelpers.climb_series(snapshots, :limited)
      assert score == RanksHelpers.rank_score("Platinum", 1, 5)
    end

    test "returns empty list for empty snapshots" do
      assert RanksHelpers.climb_series([], :constructed) == []
    end
  end

  describe "momentum_series/2" do
    test "returns {wins, losses} series with cumulative counts for :constructed" do
      snapshots = [
        %{
          occurred_at: ~U[2026-01-01 00:00:00Z],
          constructed_matches_won: 3,
          constructed_matches_lost: 1,
          limited_matches_won: 1,
          limited_matches_lost: 0
        },
        %{
          occurred_at: ~U[2026-01-02 00:00:00Z],
          constructed_matches_won: 7,
          constructed_matches_lost: 4,
          limited_matches_won: 2,
          limited_matches_lost: 1
        }
      ]

      {wins, losses} = RanksHelpers.momentum_series(snapshots, :constructed)

      assert [[_, 3], [_, 7]] = wins
      assert [[_, 1], [_, 4]] = losses
    end

    test "returns {wins, losses} series for :limited" do
      snapshots = [
        %{
          occurred_at: ~U[2026-01-01 00:00:00Z],
          constructed_matches_won: 5,
          constructed_matches_lost: 2,
          limited_matches_won: 10,
          limited_matches_lost: 3
        }
      ]

      {wins, losses} = RanksHelpers.momentum_series(snapshots, :limited)

      assert [[_, 10]] = wins
      assert [[_, 3]] = losses
    end

    test "treats nil counts as 0" do
      snapshots = [
        %{
          occurred_at: ~U[2026-01-01 00:00:00Z],
          constructed_matches_won: nil,
          constructed_matches_lost: nil,
          limited_matches_won: nil,
          limited_matches_lost: nil
        }
      ]

      {wins, losses} = RanksHelpers.momentum_series(snapshots, :constructed)
      assert [[_, 0]] = wins
      assert [[_, 0]] = losses
    end

    test "returns empty series for empty snapshots" do
      {wins, losses} = RanksHelpers.momentum_series([], :constructed)
      assert wins == []
      assert losses == []
    end
  end
end
