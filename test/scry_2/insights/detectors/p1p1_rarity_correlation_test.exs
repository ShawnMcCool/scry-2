defmodule Scry2.Insights.Detectors.P1P1RarityCorrelationTest do
  use Scry2.DataCase, async: true

  alias Scry2.Insights.Detectors.P1P1RarityCorrelation
  alias Scry2.Insights.Insight
  alias Scry2.TestFactory

  # Seeds a completed draft with a P1P1 of the given rarity plus N
  # winning and M losing matches. Wins/losses are derived at read time
  # from `matches_matches` over the draft's `deck_submitted_at` window,
  # so we plant real match rows.
  defp seed_draft_with_p1p1(rarity, wins, losses) do
    arena_id = System.unique_integer([:positive])
    TestFactory.create_card(%{arena_id: arena_id, rarity: rarity})

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    event_name = "QuickDraft_FDN_#{System.unique_integer([:positive])}"

    draft =
      TestFactory.create_draft(%{
        mtga_draft_id: event_name,
        event_name: event_name,
        format: "quick_draft",
        deck_submitted_at: now,
        completed_at: now
      })

    TestFactory.create_pick(%{
      draft: draft,
      pack_number: 1,
      pick_number: 1,
      picked_arena_id: arena_id
    })

    for n <- 1..wins//1 do
      TestFactory.create_match(%{
        event_name: event_name,
        format: "quick_draft",
        started_at: DateTime.add(now, n * 60, :second),
        won: true
      })
    end

    for n <- 1..losses//1 do
      TestFactory.create_match(%{
        event_name: event_name,
        format: "quick_draft",
        started_at: DateTime.add(now, (wins + n) * 60, :second),
        won: false
      })
    end

    draft
  end

  describe "tier/0" do
    test "is tier 1" do
      assert P1P1RarityCorrelation.tier() == 1
    end
  end

  describe "detect/1" do
    test "returns nil with no drafts" do
      assert P1P1RarityCorrelation.detect([]) == nil
    end

    test "returns nil when one bucket is below threshold" do
      for _ <- 1..6, do: seed_draft_with_p1p1("rare", 5, 2)
      for _ <- 1..2, do: seed_draft_with_p1p1("common", 3, 4)

      assert P1P1RarityCorrelation.detect([]) == nil
    end

    test "returns insight when both buckets exist with a meaningful gap" do
      # Rare/mythic P1P1: 6 drafts × 6 wins / 1 loss → 6/7 WR per draft = ~86%
      for _ <- 1..6, do: seed_draft_with_p1p1("rare", 6, 1)
      # Common/uncommon P1P1: 6 drafts × 3 wins / 4 losses → ~43% WR
      for _ <- 1..6, do: seed_draft_with_p1p1("common", 3, 4)

      assert %Insight{} = insight = P1P1RarityCorrelation.detect([])
      m = insight.measurements
      assert m["rare_n"] == 6
      assert m["other_n"] == 6
      assert_in_delta m["rare_wr"], 6 / 7, 0.01
      assert_in_delta m["other_wr"], 3 / 7, 0.01
    end
  end
end
