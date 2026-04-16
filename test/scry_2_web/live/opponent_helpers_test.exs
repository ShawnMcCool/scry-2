defmodule Scry2Web.OpponentHelpersTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2Web.OpponentHelpers

  describe "record/1" do
    test "returns {0, 0} for empty history" do
      assert OpponentHelpers.record([]) == {0, 0}
    end

    test "counts wins and losses" do
      history = [
        build_match(won: true),
        build_match(won: true),
        build_match(won: false)
      ]

      assert OpponentHelpers.record(history) == {2, 1}
    end

    test "ignores matches with nil won" do
      history = [
        build_match(won: true),
        build_match(won: nil)
      ]

      assert OpponentHelpers.record(history) == {1, 0}
    end
  end

  describe "win_rate/2" do
    test "returns nil when both counts are zero" do
      assert OpponentHelpers.win_rate(0, 0) == nil
    end

    test "returns 100.0 for all wins" do
      assert OpponentHelpers.win_rate(3, 0) == 100.0
    end

    test "returns 0.0 for all losses" do
      assert OpponentHelpers.win_rate(0, 3) == 0.0
    end

    test "returns rounded percentage for mixed record" do
      # 2/3 = 66.666...% rounded to 1 decimal
      assert OpponentHelpers.win_rate(2, 1) == 66.7
    end
  end

  describe "latest_rank/1" do
    test "returns nil for empty history" do
      assert OpponentHelpers.latest_rank([]) == nil
    end

    test "returns nil when all matches lack a rank" do
      history = [build_match(opponent_rank: nil)]
      assert OpponentHelpers.latest_rank(history) == nil
    end

    test "returns rank from the most recent match by started_at" do
      earlier = build_match(opponent_rank: "Gold 2", started_at: ~U[2026-01-01 10:00:00Z])
      later = build_match(opponent_rank: "Platinum 1", started_at: ~U[2026-01-02 10:00:00Z])

      # pass in reverse order to verify it selects by timestamp, not list position
      assert OpponentHelpers.latest_rank([later, earlier]) == "Platinum 1"
    end

    test "returns most recent known rank, skipping matches with nil rank" do
      earlier = build_match(opponent_rank: "Gold 2", started_at: ~U[2026-01-01 10:00:00Z])
      latest_no_rank = build_match(opponent_rank: nil, started_at: ~U[2026-01-02 10:00:00Z])

      assert OpponentHelpers.latest_rank([earlier, latest_no_rank]) == "Gold 2"
    end
  end

  describe "chart_series/1" do
    test "returns '[]' for fewer than 3 matches" do
      history = [build_match(), build_match()]
      assert OpponentHelpers.chart_series(history) == "[]"
    end

    test "returns JSON array of [timestamp, win_rate, label] triples with 3+ matches" do
      history = [
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: false, started_at: ~U[2026-01-03 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))

      assert length(series) == 3
      [_timestamp, rate, label] = List.last(series)
      # 2 wins out of 3 = 66.7%
      assert rate == 66.7
      assert label == "2W–1L"
    end

    test "excludes matches with nil won from series" do
      history = [
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z]),
        build_match(won: nil, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-03 10:00:00Z]),
        build_match(won: false, started_at: ~U[2026-01-04 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))
      # 3 data points (nil excluded), not 4
      assert length(series) == 3
    end

    test "sorts matches by started_at regardless of input order" do
      # pass reversed — first match chronologically is a win so first point = 100%
      history = [
        build_match(won: false, started_at: ~U[2026-01-03 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))
      [_ts, first_rate, _label] = List.first(series)
      assert first_rate == 100.0
    end
  end
end
