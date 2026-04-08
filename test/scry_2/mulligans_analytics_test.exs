defmodule Scry2.MulligansAnalyticsTest do
  use Scry2.DataCase

  alias Scry2.Mulligans
  alias Scry2.TestFactory

  describe "mulligan_analytics/1" do
    test "returns empty stats when no data" do
      stats = Mulligans.mulligan_analytics()
      assert stats.total_hands == 0
      assert stats.total_keeps == 0
      assert stats.by_hand_size == []
      assert stats.by_land_count == []
    end

    test "computes keep rate by hand size" do
      match = TestFactory.create_match(%{won: true})

      # First offer at 7 cards — mulliganed (not the last)
      Mulligans.upsert_hand!(%{
        mtga_match_id: match.mtga_match_id,
        hand_size: 7,
        land_count: 1,
        occurred_at: ~U[2026-04-08 12:00:00Z]
      })

      # Second offer at 6 cards — kept (last)
      Mulligans.upsert_hand!(%{
        mtga_match_id: match.mtga_match_id,
        hand_size: 6,
        land_count: 2,
        occurred_at: ~U[2026-04-08 12:00:01Z]
      })

      stats = Mulligans.mulligan_analytics()

      assert stats.total_hands == 2
      assert stats.total_keeps == 1

      seven = Enum.find(stats.by_hand_size, &(&1.hand_size == 7))
      assert seven.total == 1
      assert seven.keeps == 0
      assert seven.keep_rate == 0.0

      six = Enum.find(stats.by_hand_size, &(&1.hand_size == 6))
      assert six.total == 1
      assert six.keeps == 1
      assert six.keep_rate == 100.0
    end

    test "computes win rate by land count in kept hand" do
      match_won = TestFactory.create_match(%{won: true})
      match_lost = TestFactory.create_match(%{won: false})

      # Won game — kept with 3 lands
      Mulligans.upsert_hand!(%{
        mtga_match_id: match_won.mtga_match_id,
        hand_size: 7,
        land_count: 3,
        occurred_at: ~U[2026-04-08 12:00:00Z]
      })

      # Lost game — kept with 3 lands
      Mulligans.upsert_hand!(%{
        mtga_match_id: match_lost.mtga_match_id,
        hand_size: 7,
        land_count: 3,
        occurred_at: ~U[2026-04-08 13:00:00Z]
      })

      stats = Mulligans.mulligan_analytics()

      three_lands = Enum.find(stats.by_land_count, &(&1.land_count == 3))
      assert three_lands.total == 2
      assert three_lands.wins == 1
      assert three_lands.win_rate == 50.0
    end
  end
end
