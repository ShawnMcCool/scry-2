defmodule Scry2.Events.SnapshotDiffTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2.Events.SnapshotDiff

  # ── RankSnapshot ─────────────────────────────────────────────────────────

  describe "changed?/2 RankSnapshot" do
    test "returns :unchanged when rank data is identical" do
      event = build_rank_snapshot()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when constructed_class changes" do
      event = build_rank_snapshot(constructed_class: "Platinum")
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert elem(key, 0) == "Platinum"
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_rank_snapshot()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when limited_matches_won increases" do
      event = build_rank_snapshot(limited_matches_won: 5)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_rank_snapshot(limited_matches_won: 6)
      {:changed, new_key} = SnapshotDiff.changed?(updated_event, key)
      assert new_key != key
    end

    test "excludes occurred_at — same data at different times is :unchanged" do
      earlier = build_rank_snapshot(occurred_at: ~U[2026-01-01 10:00:00Z])
      later = build_rank_snapshot(occurred_at: ~U[2026-01-02 10:00:00Z])
      {:changed, key} = SnapshotDiff.changed?(earlier, nil)
      assert SnapshotDiff.changed?(later, key) == :unchanged
    end
  end

  # ── QuestStatus ───────────────────────────────────────────────────────────

  describe "changed?/2 QuestStatus" do
    test "returns :unchanged when quest list is identical" do
      event = build_quest_status()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_quest_status()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when quest progress changes" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "daily_win_1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_quest_status(
          quests: [
            %{
              quest_id: "daily_win_1",
              goal: 5,
              progress: 4,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when a new quest is added" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "daily_win_1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_quest_status(
          quests: [
            %{
              quest_id: "daily_win_1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            },
            %{
              quest_id: "weekly_win_1",
              goal: 15,
              progress: 0,
              quest_track: "Weekly",
              reward_gold: 1000,
              reward_xp: nil
            }
          ]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on quest_track field" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: nil,
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── DailyWinsStatus ───────────────────────────────────────────────────────

  describe "changed?/2 DailyWinsStatus" do
    test "returns :unchanged when positions are identical" do
      event = build_daily_wins_status()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_daily_wins_status()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when daily_position advances" do
      event = build_daily_wins_status(daily_position: 3)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_daily_wins_status(daily_position: 4)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns :unchanged when only reset times change (same positions)" do
      event =
        build_daily_wins_status(
          daily_position: 3,
          weekly_position: 10,
          daily_reset_at: ~U[2026-01-01 00:00:00Z],
          weekly_reset_at: ~U[2026-01-07 00:00:00Z]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      same_positions_new_resets =
        build_daily_wins_status(
          daily_position: 3,
          weekly_position: 10,
          daily_reset_at: ~U[2026-01-02 00:00:00Z],
          weekly_reset_at: ~U[2026-01-14 00:00:00Z]
        )

      assert SnapshotDiff.changed?(same_positions_new_resets, key) == :unchanged
    end

    test "nil→value transition on weekly_position" do
      event = build_daily_wins_status(weekly_position: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_daily_wins_status(weekly_position: 5)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── MasteryProgress ───────────────────────────────────────────────────────

  describe "changed?/2 MasteryProgress" do
    test "returns :unchanged when completed_nodes and milestone_states are identical" do
      event = build_mastery_progress()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_mastery_progress()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when completed_nodes increases" do
      event = build_mastery_progress(completed_nodes: 2)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_mastery_progress(completed_nodes: 3)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when milestone_states change" do
      event = build_mastery_progress(milestone_states: %{"TutorialComplete" => true})
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_mastery_progress(milestone_states: %{"TutorialComplete" => true, "Level10" => true})

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on milestone_states" do
      event = build_mastery_progress(milestone_states: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_mastery_progress(milestone_states: %{"TutorialComplete" => true})
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── DeckInventory ─────────────────────────────────────────────────────────

  describe "changed?/2 DeckInventory" do
    test "returns :unchanged when deck IDs are identical" do
      event = build_deck_inventory()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_deck_inventory()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when a new deck is added" do
      event =
        build_deck_inventory(
          decks: [%{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"}]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"},
            %{deck_id: "deck-ghi-789", name: "New Deck", format: "Historic"}
          ]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns :unchanged when only deck names change (same deck_ids)" do
      event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "Old Name", format: "Standard"}
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      renamed_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "New Name", format: "Standard"}
          ]
        )

      assert SnapshotDiff.changed?(renamed_event, key) == :unchanged
    end

    test "deck order does not matter — same ids in different order is :unchanged" do
      event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "Deck A", format: "Standard"},
            %{deck_id: "deck-def-456", name: "Deck B", format: "Limited"}
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      reordered_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-def-456", name: "Deck B", format: "Limited"},
            %{deck_id: "deck-abc-123", name: "Deck A", format: "Standard"}
          ]
        )

      assert SnapshotDiff.changed?(reordered_event, key) == :unchanged
    end

    test "nil→value transition on deck_id (empty to populated)" do
      event = build_deck_inventory(decks: [])
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_deck_inventory(
          decks: [%{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"}]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── CollectionUpdated ─────────────────────────────────────────────────────

  describe "changed?/2 CollectionUpdated" do
    test "returns :unchanged when card_counts map is identical" do
      event = build_collection_updated()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_collection_updated()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when a card count increases" do
      event = build_collection_updated(card_counts: %{91_234 => 2})
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4})
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when a new card is acquired" do
      event = build_collection_updated(card_counts: %{91_234 => 4})
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4, 91_235 => 1})
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on card_counts (empty map to populated)" do
      event = build_collection_updated(card_counts: %{})
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4})
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── InventorySnapshot ─────────────────────────────────────────────────────

  describe "changed?/2 InventorySnapshot" do
    test "returns :unchanged when all economy fields are identical" do
      event = build_inventory_snapshot()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_inventory_snapshot()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when gold changes" do
      event = build_inventory_snapshot(gold: 5000)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(gold: 6000)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when boosters change" do
      event = build_inventory_snapshot(boosters: [%{set_code: "FDN", count: 3}])
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(boosters: [%{set_code: "FDN", count: 4}])
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on gems" do
      event = build_inventory_snapshot(gems: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(gems: 1200)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── InventoryUpdated ──────────────────────────────────────────────────────

  describe "changed?/2 InventoryUpdated" do
    test "returns :unchanged when all economy fields are identical" do
      event = build_inventory_updated()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_inventory_updated()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when wildcards_rare changes" do
      event = build_inventory_updated(wildcards_rare: 6)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(wildcards_rare: 7)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when vault_progress changes" do
      event = build_inventory_updated(vault_progress: 42.5)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(vault_progress: 55.0)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on draft_tokens" do
      event = build_inventory_updated(draft_tokens: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(draft_tokens: 1)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── EventCourseUpdated ────────────────────────────────────────────────────

  describe "changed?/2 EventCourseUpdated" do
    test "returns :unchanged when all course fields are identical" do
      event = build_event_course_updated()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_event_course_updated()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when current_wins increases" do
      event = build_event_course_updated(current_wins: 2)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_event_course_updated(current_wins: 3)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "different event_names produce different keys and do not collide" do
      quick_draft =
        build_event_course_updated(
          event_name: "QuickDraft_FDN_20260323",
          current_wins: 2
        )

      premier_draft =
        build_event_course_updated(
          event_name: "PremierDraft_FDN_20260401",
          current_wins: 2
        )

      {:changed, quick_key} = SnapshotDiff.changed?(quick_draft, nil)
      assert {:changed, _premier_key} = SnapshotDiff.changed?(premier_draft, quick_key)
    end

    test "nil→value transition on current_module" do
      event = build_event_course_updated(current_module: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_event_course_updated(current_module: "Draft")
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when card_pool grows (new pick added)" do
      event = build_event_course_updated(card_pool: [91_234, 91_235])
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_event_course_updated(card_pool: [91_234, 91_235, 91_236])
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns :unchanged when card_pool is identical despite other noise" do
      event =
        build_event_course_updated(
          card_pool: [91_234, 91_235],
          occurred_at: ~U[2026-01-01 10:00:00Z]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      same_pool_later =
        build_event_course_updated(
          card_pool: [91_234, 91_235],
          occurred_at: ~U[2026-01-01 10:05:00Z]
        )

      assert SnapshotDiff.changed?(same_pool_later, key) == :unchanged
    end
  end
end
