defmodule Scry2.MatchEconomy.AggregateLogTest do
  use Scry2.DataCase, async: false
  import Scry2.TestFactory
  alias Scry2.MatchEconomy.AggregateLog

  describe "gold_gems/2" do
    test "sums transactions in [start, end] inclusive" do
      start_at = ~U[2026-04-30 10:00:00.000000Z]
      end_at = ~U[2026-04-30 11:00:00.000000Z]

      create_economy_transaction(occurred_at: ~U[2026-04-30 09:30:00Z], gold_delta: 999)
      create_economy_transaction(occurred_at: start_at, gold_delta: 100, gems_delta: 5)
      create_economy_transaction(occurred_at: ~U[2026-04-30 10:30:00Z], gold_delta: 50)
      create_economy_transaction(occurred_at: end_at, gold_delta: 25, gems_delta: 1)
      create_economy_transaction(occurred_at: ~U[2026-04-30 11:01:00Z], gold_delta: 999)

      assert AggregateLog.gold_gems(start_at, end_at) == %{gold: 175, gems: 6}
    end

    test "returns zero map when no transactions in window" do
      assert AggregateLog.gold_gems(~U[2026-04-30 10:00:00Z], ~U[2026-04-30 11:00:00Z]) ==
               %{gold: 0, gems: 0}
    end

    test "treats nil deltas as zero" do
      create_economy_transaction(
        occurred_at: ~U[2026-04-30 10:30:00Z],
        gold_delta: nil,
        gems_delta: 5
      )

      assert AggregateLog.gold_gems(~U[2026-04-30 10:00:00Z], ~U[2026-04-30 11:00:00Z]) ==
               %{gold: 0, gems: 5}
    end
  end

  describe "wildcards/2" do
    test "diffs the most-recent snapshot at or before each window boundary" do
      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 09:50:00Z],
        wildcards_common: 10,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 11:00:00Z],
        wildcards_common: 11,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      assert AggregateLog.wildcards(~U[2026-04-30 10:00:00Z], ~U[2026-04-30 11:00:00Z]) == %{
               common: 1,
               uncommon: 0,
               rare: 0,
               mythic: 0
             }
    end

    test "returns all-nil when no pre-window snapshot exists" do
      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 11:00:00Z],
        wildcards_common: 11,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      assert AggregateLog.wildcards(~U[2026-04-30 10:00:00Z], ~U[2026-04-30 11:00:00Z]) == %{
               common: nil,
               uncommon: nil,
               rare: nil,
               mythic: nil
             }
    end

    test "returns zero diff when only a pre-window snapshot exists (post falls through to same row)" do
      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 09:50:00Z],
        wildcards_common: 10,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      assert AggregateLog.wildcards(~U[2026-04-30 10:00:00Z], ~U[2026-04-30 11:00:00Z]) == %{
               common: 0,
               uncommon: 0,
               rare: 0,
               mythic: 0
             }
    end
  end
end
