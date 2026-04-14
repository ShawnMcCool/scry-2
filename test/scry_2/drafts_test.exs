defmodule Scry2.DraftsTest do
  use Scry2.DataCase

  import Scry2.TestFactory

  alias Scry2.Drafts

  describe "list_drafts/1" do
    test "returns drafts newest first" do
      older = create_draft(%{started_at: ~U[2026-01-01 00:00:00Z]})
      newer = create_draft(%{started_at: ~U[2026-01-02 00:00:00Z]})

      results = Drafts.list_drafts()
      ids = Enum.map(results, & &1.id)
      assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))
    end

    test "respects limit" do
      for _ <- 1..5, do: create_draft(%{})
      results = Drafts.list_drafts(limit: 3)
      assert length(results) == 3
    end

    test "filters by player_id" do
      player_a = create_player()
      player_b = create_player()
      mine = create_draft(%{player_id: player_a.id})
      _theirs = create_draft(%{player_id: player_b.id})

      results = Drafts.list_drafts(player_id: player_a.id)
      assert length(results) == 1
      assert hd(results).id == mine.id
    end
  end

  describe "list_drafts/1 with filters" do
    test "filters by format" do
      player = create_player()
      _qd = create_draft(%{player_id: player.id, format: "quick_draft"})
      pd = create_draft(%{player_id: player.id, format: "premier_draft"})

      results = Drafts.list_drafts(player_id: player.id, format: "premier_draft")
      assert length(results) == 1
      assert hd(results).id == pd.id
    end

    test "filters by set_code" do
      player = create_player()
      fdn = create_draft(%{player_id: player.id, set_code: "FDN"})
      _blb = create_draft(%{player_id: player.id, set_code: "BLB"})

      results = Drafts.list_drafts(player_id: player.id, set_code: "FDN")
      assert length(results) == 1
      assert hd(results).id == fdn.id
    end
  end

  describe "draft_stats/1" do
    test "returns zeros when no drafts" do
      player = create_player()
      stats = Drafts.draft_stats(player_id: player.id)
      assert stats.total == 0
      assert stats.win_rate == nil
      assert stats.avg_wins == nil
      assert stats.trophies == 0
      assert stats.by_format == []
    end

    test "computes total, win_rate, avg_wins, trophies" do
      player = create_player()

      create_draft(%{
        player_id: player.id,
        wins: 7,
        losses: 0,
        completed_at: DateTime.utc_now(:second),
        format: "quick_draft"
      })

      create_draft(%{
        player_id: player.id,
        wins: 3,
        losses: 3,
        completed_at: DateTime.utc_now(:second),
        format: "quick_draft"
      })

      create_draft(%{
        player_id: player.id,
        wins: nil,
        losses: nil,
        completed_at: nil,
        format: "quick_draft"
      })

      stats = Drafts.draft_stats(player_id: player.id)
      assert stats.total == 3
      assert stats.trophies == 1
      # 10/(10+3) — 7+3 wins, 0+3 losses across 2 complete drafts
      assert_in_delta stats.win_rate, 0.769, 0.01
      # (7+3)/2 complete drafts
      assert_in_delta stats.avg_wins, 5.0, 0.01
    end

    test "by_format breakdown" do
      player = create_player()

      create_draft(%{
        player_id: player.id,
        wins: 6,
        losses: 1,
        completed_at: DateTime.utc_now(:second),
        format: "quick_draft"
      })

      create_draft(%{
        player_id: player.id,
        wins: 2,
        losses: 3,
        completed_at: DateTime.utc_now(:second),
        format: "premier_draft"
      })

      stats = Drafts.draft_stats(player_id: player.id)
      qd = Enum.find(stats.by_format, &(&1.format == "quick_draft"))
      pd = Enum.find(stats.by_format, &(&1.format == "premier_draft"))

      assert qd.total == 1
      assert_in_delta qd.win_rate, 0.857, 0.01
      assert pd.total == 1
      assert_in_delta pd.win_rate, 0.4, 0.01
    end
  end
end
