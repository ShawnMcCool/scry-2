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

  describe "upsert_draft!/1" do
    test "second call with same mtga_draft_id updates instead of inserting" do
      player = create_player()
      mtga_id = "QuickDraft_FDN_#{System.unique_integer([:positive])}"

      first =
        Drafts.upsert_draft!(%{
          player_id: player.id,
          mtga_draft_id: mtga_id,
          format: "quick_draft"
        })

      second =
        Drafts.upsert_draft!(%{
          player_id: player.id,
          mtga_draft_id: mtga_id,
          format: "premier_draft"
        })

      assert first.id == second.id
      assert Drafts.count() == 1
      assert second.format == "premier_draft"
    end
  end

  describe "upsert_pick!/1" do
    test "second call with same (draft_id, pack, pick) updates instead of inserting" do
      player = create_player()
      draft = create_draft(%{player_id: player.id})

      first =
        Drafts.upsert_pick!(%{
          draft_id: draft.id,
          pack_number: 1,
          pick_number: 1,
          picked_arena_id: 11_111
        })

      second =
        Drafts.upsert_pick!(%{
          draft_id: draft.id,
          pack_number: 1,
          pick_number: 1,
          picked_arena_id: 22_222
        })

      assert first.id == second.id
      assert Scry2.Repo.aggregate(Scry2.Drafts.Pick, :count) == 1
      assert second.picked_arena_id == 22_222
    end
  end

  describe "get_draft_with_picks/1" do
    test "returns picks ordered by pack then pick number" do
      draft = create_draft(%{})

      create_pick(%{draft: draft, pack_number: 2, pick_number: 1, picked_arena_id: 300})
      create_pick(%{draft: draft, pack_number: 1, pick_number: 2, picked_arena_id: 200})
      create_pick(%{draft: draft, pack_number: 1, pick_number: 1, picked_arena_id: 100})

      result = Drafts.get_draft_with_picks(draft.id)
      pick_numbers = Enum.map(result.picks, & &1.picked_arena_id)
      assert pick_numbers == [100, 200, 300]
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

    test "attributes matches to a Quick Draft by event_name + window from deck_submitted_at" do
      player = create_player()
      event_name = "QuickDraft_FDN_20260323"

      create_draft(%{
        player_id: player.id,
        event_name: event_name,
        mtga_draft_id: event_name,
        format: "quick_draft",
        deck_submitted_at: ~U[2026-04-01 00:00:00Z],
        completed_at: ~U[2026-04-01 00:00:00Z]
      })

      # 5 matches, all after deck submission → 3-2
      seed_matches(player.id, event_name, "quick_draft", ~U[2026-04-01 00:10:00Z], [
        true,
        false,
        true,
        true,
        false
      ])

      stats = Drafts.draft_stats(player_id: player.id)
      qd = Enum.find(stats.by_format, &(&1.format == "quick_draft"))
      assert qd.total == 1
      assert_in_delta qd.win_rate, 0.6, 0.01
    end

    test "two Pick Two drafts sharing event_name partition matches by deck_submitted_at window" do
      player = create_player()
      event_name = "PickTwoDraft_SOS_20260421"

      _draft_a =
        create_draft(%{
          player_id: player.id,
          event_name: event_name,
          mtga_draft_id: "course-a",
          format: "pick_two_draft",
          deck_submitted_at: ~U[2026-05-14 17:50:00Z],
          completed_at: ~U[2026-05-14 17:50:00Z]
        })

      _draft_b =
        create_draft(%{
          player_id: player.id,
          event_name: event_name,
          mtga_draft_id: "course-b",
          format: "pick_two_draft",
          deck_submitted_at: ~U[2026-05-15 17:35:00Z],
          completed_at: ~U[2026-05-15 17:35:00Z]
        })

      # All 5 matches fall in draft_a's window [2026-05-14 17:50, 2026-05-15 17:35)
      seed_matches(player.id, event_name, "pick_two_draft", ~U[2026-05-15 14:00:00Z], [
        true,
        false,
        true,
        false,
        true
      ])

      # draft_b has no matches yet (latest draft, open window)

      stats = Drafts.draft_stats(player_id: player.id)
      pick_two = Enum.find(stats.by_format, &(&1.format == "pick_two_draft"))
      assert pick_two.total == 2
      # Combined 3 wins, 2 losses → 60%
      assert_in_delta pick_two.win_rate, 0.6, 0.01
    end

    test "matches BEFORE deck_submitted_at do not count toward the draft" do
      player = create_player()
      event_name = "PremierDraft_SOS_20260421"

      create_draft(%{
        player_id: player.id,
        event_name: event_name,
        mtga_draft_id: "course-premier-1",
        format: "premier_draft",
        deck_submitted_at: ~U[2026-05-15 18:00:00Z],
        completed_at: ~U[2026-05-15 18:00:00Z]
      })

      # match before submission — not attributable
      create_match(%{
        player_id: player.id,
        event_name: event_name,
        format: "premier_draft",
        started_at: ~U[2026-05-15 14:00:00Z],
        won: true
      })

      # match after submission — attributed
      create_match(%{
        player_id: player.id,
        event_name: event_name,
        format: "premier_draft",
        started_at: ~U[2026-05-15 19:00:00Z],
        won: false
      })

      stats = Drafts.draft_stats(player_id: player.id)
      premier = Enum.find(stats.by_format, &(&1.format == "premier_draft"))
      assert premier.total == 1
      # 0 wins, 1 loss → 0%
      assert_in_delta premier.win_rate, 0.0, 0.01
    end

    test "counts trophies when a draft has 7 wins" do
      player = create_player()
      event_name = "QuickDraft_TMT_20260407"

      create_draft(%{
        player_id: player.id,
        event_name: event_name,
        mtga_draft_id: event_name,
        format: "quick_draft",
        deck_submitted_at: ~U[2026-04-07 00:00:00Z],
        completed_at: ~U[2026-04-07 00:00:00Z]
      })

      seed_matches(
        player.id,
        event_name,
        "quick_draft",
        ~U[2026-04-07 00:10:00Z],
        List.duplicate(true, 7)
      )

      stats = Drafts.draft_stats(player_id: player.id)
      assert stats.trophies == 1
    end

    test "drafts with nil deck_submitted_at attract no matches" do
      player = create_player()
      event_name = "QuickDraft_FDN_20260323"

      # No deck_submitted_at — draft was started but deck never submitted
      create_draft(%{
        player_id: player.id,
        event_name: event_name,
        mtga_draft_id: event_name,
        format: "quick_draft",
        deck_submitted_at: nil,
        completed_at: nil
      })

      # Match exists with this event_name but should not attach to any draft
      create_match(%{
        player_id: player.id,
        event_name: event_name,
        format: "quick_draft",
        started_at: ~U[2026-04-01 12:00:00Z],
        won: true
      })

      stats = Drafts.draft_stats(player_id: player.id)
      qd = Enum.find(stats.by_format, &(&1.format == "quick_draft"))
      assert qd.total == 1
      # Draft has no submitted deck → win rate is nil (no wins/losses recorded)
      assert qd.win_rate == nil
    end
  end

  defp seed_matches(player_id, event_name, format, start_time, wins) do
    wins
    |> Enum.with_index()
    |> Enum.each(fn {won, idx} ->
      create_match(%{
        player_id: player_id,
        event_name: event_name,
        format: format,
        started_at: DateTime.add(start_time, idx * 600, :second),
        won: won
      })
    end)
  end
end
