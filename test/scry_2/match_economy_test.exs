defmodule Scry2.MatchEconomyTest do
  use Scry2.DataCase, async: true
  import Scry2.TestFactory
  alias Scry2.MatchEconomy
  alias Scry2.MatchEconomy.Summary

  describe "upsert_summary!/1" do
    test "inserts a new row when mtga_match_id is fresh" do
      attrs = %{mtga_match_id: "x-1", reconciliation_state: "incomplete"}
      row = MatchEconomy.upsert_summary!(attrs)
      assert row.mtga_match_id == "x-1"
      assert row.id != nil
    end

    test "updates the existing row by mtga_match_id" do
      _first = create_match_economy_summary(mtga_match_id: "x-2", memory_gold_delta: 100)

      updated =
        MatchEconomy.upsert_summary!(%{
          mtga_match_id: "x-2",
          reconciliation_state: "complete",
          memory_gold_delta: 250
        })

      assert updated.memory_gold_delta == 250
      assert updated.reconciliation_state == "complete"
      assert Scry2.Repo.aggregate(Summary, :count) == 1
    end
  end

  describe "get_summary/1" do
    test "returns the row by mtga_match_id" do
      create_match_economy_summary(mtga_match_id: "g-1")
      assert %Summary{mtga_match_id: "g-1"} = MatchEconomy.get_summary("g-1")
    end

    test "returns nil when not found" do
      assert MatchEconomy.get_summary("nonexistent") == nil
    end
  end

  describe "recent_summaries/1" do
    test "returns most recent first by ended_at, capped at limit" do
      create_match_economy_summary(mtga_match_id: "r-old", ended_at: ~U[2026-04-29 10:00:00Z])
      create_match_economy_summary(mtga_match_id: "r-new", ended_at: ~U[2026-04-30 10:00:00Z])
      create_match_economy_summary(mtga_match_id: "r-mid", ended_at: ~U[2026-04-29 20:00:00Z])

      ids = MatchEconomy.recent_summaries(limit: 2) |> Enum.map(& &1.mtga_match_id)
      assert ids == ["r-new", "r-mid"]
    end

    test "skips rows with nil ended_at" do
      create_match_economy_summary(mtga_match_id: "orphan", ended_at: nil)
      create_match_economy_summary(mtga_match_id: "real", ended_at: ~U[2026-04-30 10:00:00Z])

      ids = MatchEconomy.recent_summaries(limit: 10) |> Enum.map(& &1.mtga_match_id)
      assert ids == ["real"]
    end
  end

  describe "timeline/1" do
    test "buckets summaries by UTC date and sums memory gold delta" do
      create_match_economy_summary(
        mtga_match_id: "t-1",
        ended_at: ~U[2026-04-29 10:00:00Z],
        memory_gold_delta: 100
      )

      create_match_economy_summary(
        mtga_match_id: "t-2",
        ended_at: ~U[2026-04-29 22:00:00Z],
        memory_gold_delta: 250
      )

      create_match_economy_summary(
        mtga_match_id: "t-3",
        ended_at: ~U[2026-04-30 10:00:00Z],
        memory_gold_delta: 75
      )

      buckets = MatchEconomy.timeline([])

      assert Enum.find(buckets, &(&1.date == ~D[2026-04-29])).gold == 350
      assert Enum.find(buckets, &(&1.date == ~D[2026-04-30])).gold == 75
    end
  end
end
