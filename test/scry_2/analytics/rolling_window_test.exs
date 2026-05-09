defmodule Scry2.Analytics.RollingWindowTest do
  use ExUnit.Case, async: true

  alias Scry2.Analytics.RollingWindow

  defp row(offset_seconds, won) do
    %{started_at: DateTime.add(~U[2026-05-01 00:00:00Z], offset_seconds, :second), won: won}
  end

  describe "cumulative_points/1" do
    test "empty input → empty output" do
      assert RollingWindow.cumulative_points([]) == []
    end

    test "computes a running win rate at each point" do
      rows = [row(0, true), row(60, false), row(120, true), row(180, true)]

      points = RollingWindow.cumulative_points(rows)

      assert Enum.map(points, & &1.win_rate) == [100.0, 50.0, 66.7, 75.0]
      assert Enum.map(points, & &1.wins) == [1, 1, 2, 3]
      assert Enum.map(points, & &1.total) == [1, 2, 3, 4]
    end

    test "single loss → 0.0% win rate, not nil" do
      [point] = RollingWindow.cumulative_points([row(0, false)])
      assert point.win_rate == 0.0
      assert point.wins == 0
      assert point.total == 1
    end
  end

  describe "rolling_points/2" do
    test "empty input → empty output" do
      assert RollingWindow.rolling_points([], 7) == []
    end

    test "fewer than 5 samples → no emitted points" do
      rows = for n <- 0..3, do: row(n * 60, true)
      assert RollingWindow.rolling_points(rows, 7) == []
    end

    test "emits a point once the 5-sample threshold is reached" do
      rows = [
        row(0, true),
        row(60, true),
        row(120, false),
        row(180, true),
        row(240, false),
        row(300, true)
      ]

      points = RollingWindow.rolling_points(rows, 7)

      assert length(points) == 2
      assert Enum.at(points, 0).total == 5
      assert Enum.at(points, 1).total == 6
      assert Enum.at(points, 0).wins == 3
      assert Enum.at(points, 1).wins == 4
    end

    test "rows outside the window are excluded from the count" do
      day = 86_400

      rows = [
        row(0, true),
        row(day, true),
        row(2 * day, true),
        row(3 * day, true),
        row(4 * day, true),
        # 8 days later: only includes rows >= seven_days, so the row at 0 falls off
        row(8 * day, false)
      ]

      points = RollingWindow.rolling_points(rows, 7)

      # Only the first 5-row window (rows 0..4) emits a point: total=5, wins=5.
      # The 6th row's window starts at (8d - 7d) = 1d, capturing rows at 1d..4d
      # plus itself — only 5 rows including the loss at day 8 → window of 5
      # totals (4 wins + 1 loss).
      assert length(points) == 2
      assert Enum.at(points, 0).total == 5
      assert Enum.at(points, 0).wins == 5
      assert Enum.at(points, 1).total == 5
      assert Enum.at(points, 1).wins == 4
    end

    test "emits points in ascending timestamp order" do
      rows = for n <- 0..9, do: row(n * 60, rem(n, 2) == 0)

      points = RollingWindow.rolling_points(rows, 7)
      timestamps = Enum.map(points, & &1.timestamp)

      assert timestamps == Enum.sort(timestamps)
    end
  end

  describe "filter_to_display_window/3" do
    test "keeps points within [now - days, now]" do
      now = ~U[2026-05-08 00:00:00Z]

      points = [
        %{timestamp: "2026-04-30T00:00:00Z", win_rate: 50.0, wins: 1, total: 2},
        %{timestamp: "2026-05-05T00:00:00Z", win_rate: 60.0, wins: 3, total: 5},
        %{timestamp: "2026-05-08T00:00:00Z", win_rate: 70.0, wins: 7, total: 10}
      ]

      kept = RollingWindow.filter_to_display_window(points, 7, now)

      assert Enum.map(kept, & &1.timestamp) == [
               "2026-05-05T00:00:00Z",
               "2026-05-08T00:00:00Z"
             ]
    end
  end
end
