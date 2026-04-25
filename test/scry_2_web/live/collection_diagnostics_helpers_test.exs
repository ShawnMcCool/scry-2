defmodule Scry2Web.CollectionDiagnosticsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.CollectionDiagnosticsHelpers, as: H

  describe "activity_series/1" do
    test "returns an empty pair when there are no diffs" do
      assert H.activity_series([]) == %{acquired: [], removed: []}
    end

    test "splits acquired and removed totals into two ECharts series, oldest-first" do
      diffs = [
        %{inserted_at: ~U[2026-04-22 12:00:00.000000Z], total_acquired: 8, total_removed: 0},
        %{inserted_at: ~U[2026-04-23 12:00:00.000000Z], total_acquired: 2, total_removed: 1},
        %{inserted_at: ~U[2026-04-24 12:00:00.000000Z], total_acquired: 0, total_removed: 0}
      ]

      assert H.activity_series(diffs) == %{
               acquired: [
                 ["2026-04-22T12:00:00.000000Z", 8],
                 ["2026-04-23T12:00:00.000000Z", 2],
                 ["2026-04-24T12:00:00.000000Z", 0]
               ],
               removed: [
                 ["2026-04-22T12:00:00.000000Z", 0],
                 ["2026-04-23T12:00:00.000000Z", 1],
                 ["2026-04-24T12:00:00.000000Z", 0]
               ]
             }
    end

    test "sorts diffs by inserted_at ascending regardless of input order" do
      diffs = [
        %{inserted_at: ~U[2026-04-24 12:00:00.000000Z], total_acquired: 1, total_removed: 0},
        %{inserted_at: ~U[2026-04-22 12:00:00.000000Z], total_acquired: 8, total_removed: 0}
      ]

      %{acquired: [first, _]} = H.activity_series(diffs)
      assert first == ["2026-04-22T12:00:00.000000Z", 8]
    end
  end

  describe "growth_series/1" do
    test "returns the snapshot total_copies as a time series, oldest-first" do
      snapshots = [
        %{snapshot_ts: ~U[2026-04-22 12:00:00.000000Z], total_copies: 100},
        %{snapshot_ts: ~U[2026-04-23 12:00:00.000000Z], total_copies: 108},
        %{snapshot_ts: ~U[2026-04-24 12:00:00.000000Z], total_copies: 110}
      ]

      assert H.growth_series(snapshots) == [
               ["2026-04-22T12:00:00.000000Z", 100],
               ["2026-04-23T12:00:00.000000Z", 108],
               ["2026-04-24T12:00:00.000000Z", 110]
             ]
    end

    test "empty input yields empty series" do
      assert H.growth_series([]) == []
    end
  end

  describe "refresh_dots_series/1" do
    test "tags each snapshot with its reader confidence for dot coloring" do
      snapshots = [
        %{snapshot_ts: ~U[2026-04-22 12:00:00.000000Z], reader_confidence: "fallback_scan"},
        %{snapshot_ts: ~U[2026-04-23 12:00:00.000000Z], reader_confidence: "walker"}
      ]

      assert H.refresh_dots_series(snapshots) == [
               %{ts: "2026-04-22T12:00:00.000000Z", confidence: "fallback_scan"},
               %{ts: "2026-04-23T12:00:00.000000Z", confidence: "walker"}
             ]
    end
  end

  describe "noise_signal_ratio/2" do
    test "returns nil when no diffs exist (avoids divide-by-zero)" do
      assert H.noise_signal_ratio(0, 0) == nil
    end

    test "returns the share of non-empty diffs as a 0..1 float" do
      assert H.noise_signal_ratio(10, 3) == 0.7
      assert H.noise_signal_ratio(5, 5) == 0.0
      assert H.noise_signal_ratio(4, 0) == 1.0
    end
  end

  describe "walker_share/1" do
    test "returns nil when no snapshots exist (avoids divide-by-zero)" do
      assert H.walker_share(%{walker: 0, fallback_scan: 0}) == nil
    end

    test "returns the walker share as a 0..1 float rounded to 2 decimals" do
      assert H.walker_share(%{walker: 0, fallback_scan: 5}) == 0.0
      assert H.walker_share(%{walker: 5, fallback_scan: 0}) == 1.0
      assert H.walker_share(%{walker: 1, fallback_scan: 3}) == 0.25
      assert H.walker_share(%{walker: 1, fallback_scan: 2}) == 0.33
    end
  end

  describe "format_percent/1" do
    test "formats a 0..1 float as a percent string" do
      assert H.format_percent(0.0) == "0%"
      assert H.format_percent(0.7) == "70%"
      assert H.format_percent(1.0) == "100%"
      assert H.format_percent(nil) == "—"
    end
  end

  describe "format_count/1" do
    test "renders integers with comma separators" do
      assert H.format_count(0) == "0"
      assert H.format_count(123) == "123"
      assert H.format_count(1_234_567) == "1,234,567"
    end
  end
end
