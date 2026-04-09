defmodule Scry2.Events.SnapshotConvertTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2.Events.Economy.{CardsAcquired, CardsRemoved}

  alias Scry2.Events.Event.EventRecordChanged

  alias Scry2.Events.Progression.{
    DailyWinEarned,
    MasteryMilestoneReached,
    QuestAssigned,
    QuestCompleted,
    QuestProgressed,
    RankAdvanced,
    RankMatchRecorded,
    WeeklyWinEarned
  }

  alias Scry2.Events.SnapshotConvert

  # ── RankSnapshot ─────────────────────────────────────────────────────────

  describe "convert/2 RankSnapshot" do
    test "returns :unchanged when key is identical" do
      event = build_rank_snapshot()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) emits RankAdvanced only" do
      event = build_rank_snapshot()
      assert {:converted, _key, events} = SnapshotConvert.convert(event, nil)
      assert [%RankAdvanced{}] = events
    end

    test "RankAdvanced has all rank fields copied from snapshot" do
      event =
        build_rank_snapshot(
          constructed_class: "Gold",
          constructed_level: 2,
          constructed_step: 3,
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_class: "Silver",
          limited_level: 1,
          limited_step: 0,
          limited_matches_won: 5,
          limited_matches_lost: 3,
          season_ordinal: 88
        )

      {:converted, _key, [rank_advanced | _]} = SnapshotConvert.convert(event, nil)

      assert rank_advanced.constructed_class == "Gold"
      assert rank_advanced.constructed_level == 2
      assert rank_advanced.constructed_step == 3
      assert rank_advanced.constructed_matches_won == 15
      assert rank_advanced.constructed_matches_lost == 10
      assert rank_advanced.limited_class == "Silver"
      assert rank_advanced.limited_level == 1
      assert rank_advanced.limited_step == 0
      assert rank_advanced.limited_matches_won == 5
      assert rank_advanced.limited_matches_lost == 3
      assert rank_advanced.season_ordinal == 88
    end

    test "RankAdvanced copies player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 10:00:00Z]
      event = build_rank_snapshot(player_id: "player-123", occurred_at: occurred_at)
      {:converted, _key, [rank_advanced | _]} = SnapshotConvert.convert(event, nil)
      assert rank_advanced.player_id == "player-123"
      assert rank_advanced.occurred_at == occurred_at
    end

    test "rank change with no match record change emits only RankAdvanced" do
      event =
        build_rank_snapshot(
          constructed_class: "Gold",
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, key, _events} = SnapshotConvert.convert(event, nil)

      # Change only rank class, not win/loss counts
      updated_event =
        build_rank_snapshot(
          constructed_class: "Platinum",
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 1
      assert [%RankAdvanced{}] = events
    end

    test "constructed wins increasing emits RankAdvanced + RankMatchRecorded for constructed" do
      event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_rank_snapshot(
          constructed_matches_won: 16,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, _key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 2

      assert [
               %RankAdvanced{},
               %RankMatchRecorded{format: :constructed, won: true, wins: 16, losses: 10}
             ] = events
    end

    test "constructed losses increasing emits RankMatchRecorded with won: false" do
      event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 11,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, _key, events} = SnapshotConvert.convert(updated_event, key)

      assert [
               %RankAdvanced{},
               %RankMatchRecorded{format: :constructed, won: false, wins: 15, losses: 11}
             ] = events
    end

    test "limited wins increasing emits RankMatchRecorded for limited" do
      event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 6,
          limited_matches_lost: 3
        )

      {:converted, _key, events} = SnapshotConvert.convert(updated_event, key)

      assert [
               %RankAdvanced{},
               %RankMatchRecorded{format: :limited, won: true, wins: 6, losses: 3}
             ] = events
    end

    test "both formats changing emits two RankMatchRecorded events" do
      event =
        build_rank_snapshot(
          constructed_matches_won: 15,
          constructed_matches_lost: 10,
          limited_matches_won: 5,
          limited_matches_lost: 3
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_rank_snapshot(
          constructed_matches_won: 16,
          constructed_matches_lost: 10,
          limited_matches_won: 6,
          limited_matches_lost: 3
        )

      {:converted, _key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 3

      assert [
               %RankAdvanced{},
               %RankMatchRecorded{format: :constructed},
               %RankMatchRecorded{format: :limited}
             ] = events
    end

    test "key contains all 11 rank fields" do
      event = build_rank_snapshot()
      {:converted, key, _} = SnapshotConvert.convert(event, nil)
      assert tuple_size(key) == 11
    end
  end

  # ── DailyWinsStatus ───────────────────────────────────────────────────────

  describe "convert/2 DailyWinsStatus" do
    test "returns :unchanged when key is identical" do
      event = build_daily_wins_status()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) returns converted with empty events" do
      event = build_daily_wins_status()
      assert {:converted, _key, []} = SnapshotConvert.convert(event, nil)
    end

    test "daily_position advancing emits DailyWinEarned" do
      event = build_daily_wins_status(daily_position: 3, weekly_position: 10)
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_daily_wins_status(daily_position: 4, weekly_position: 10)
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%DailyWinEarned{new_position: 4}] = events
    end

    test "weekly_position advancing emits WeeklyWinEarned" do
      event = build_daily_wins_status(daily_position: 3, weekly_position: 10)
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_daily_wins_status(daily_position: 3, weekly_position: 11)
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%WeeklyWinEarned{new_position: 11}] = events
    end

    test "both positions advancing emits both events" do
      event = build_daily_wins_status(daily_position: 3, weekly_position: 10)
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_daily_wins_status(daily_position: 4, weekly_position: 11)
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 2
      assert Enum.any?(events, &match?(%DailyWinEarned{}, &1))
      assert Enum.any?(events, &match?(%WeeklyWinEarned{}, &1))
    end

    test "position decreasing (reset) returns converted with empty events but updates key" do
      event = build_daily_wins_status(daily_position: 5, weekly_position: 15)
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      # Simulate daily reset
      reset_event = build_daily_wins_status(daily_position: 1, weekly_position: 15)
      assert {:converted, new_key, []} = SnapshotConvert.convert(reset_event, key)
      assert new_key == {1, 15}
    end

    test "emitted events copy player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 12:00:00Z]

      event =
        build_daily_wins_status(daily_position: 1, weekly_position: 1, occurred_at: occurred_at)

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_daily_wins_status(
          player_id: "player-abc",
          daily_position: 2,
          weekly_position: 1,
          occurred_at: occurred_at
        )

      {:converted, _key, [daily_earned]} = SnapshotConvert.convert(updated_event, key)
      assert daily_earned.player_id == "player-abc"
      assert daily_earned.occurred_at == occurred_at
    end
  end

  # ── CollectionUpdated ─────────────────────────────────────────────────────

  describe "convert/2 CollectionUpdated" do
    test "returns :unchanged when card_counts map is identical" do
      event = build_collection_updated()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) emits CardsAcquired with full card_counts" do
      card_counts = %{91_234 => 4, 91_235 => 2}
      event = build_collection_updated(card_counts: card_counts)
      {:converted, _key, events} = SnapshotConvert.convert(event, nil)

      assert [%CardsAcquired{cards: ^card_counts}] = events
    end

    test "new card appearing emits CardsAcquired with delta" do
      event = build_collection_updated(card_counts: %{91_234 => 4})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4, 91_235 => 2})
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%CardsAcquired{cards: %{91_235 => 2}}] = events
    end

    test "card count increasing emits CardsAcquired with the increase delta" do
      event = build_collection_updated(card_counts: %{91_234 => 2})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4})
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%CardsAcquired{cards: %{91_234 => 2}}] = events
    end

    test "card count decreasing emits CardsRemoved with the decrease delta" do
      event = build_collection_updated(card_counts: %{91_234 => 4})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 2})
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%CardsRemoved{cards: %{91_234 => 2}}] = events
    end

    test "card disappearing entirely emits CardsRemoved" do
      event = build_collection_updated(card_counts: %{91_234 => 4, 91_235 => 1})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 4})
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%CardsRemoved{cards: %{91_235 => 1}}] = events
    end

    test "simultaneous acquisition and removal emits both events" do
      event = build_collection_updated(card_counts: %{91_234 => 4, 91_235 => 2})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_collection_updated(card_counts: %{91_234 => 6, 91_235 => 1})
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 2
      assert Enum.any?(events, &match?(%CardsAcquired{cards: %{91_234 => 2}}, &1))
      assert Enum.any?(events, &match?(%CardsRemoved{cards: %{91_235 => 1}}, &1))
    end

    test "emitted events copy player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 12:00:00Z]
      event = build_collection_updated(card_counts: %{91_234 => 4})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_collection_updated(
          player_id: "player-abc",
          card_counts: %{91_234 => 6},
          occurred_at: occurred_at
        )

      {:converted, _key, [acquired]} = SnapshotConvert.convert(updated_event, key)
      assert acquired.player_id == "player-abc"
      assert acquired.occurred_at == occurred_at
    end
  end

  # ── EventCourseUpdated ────────────────────────────────────────────────────

  describe "convert/2 EventCourseUpdated" do
    test "returns :unchanged when key is identical" do
      event = build_event_course_updated()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) emits EventRecordChanged" do
      event =
        build_event_course_updated(
          event_name: "QuickDraft_FDN_20260323",
          current_wins: 2,
          current_losses: 1
        )

      {:converted, _key, events} = SnapshotConvert.convert(event, nil)

      assert [%EventRecordChanged{event_name: "QuickDraft_FDN_20260323", wins: 2, losses: 1}] =
               events
    end

    test "wins changing emits EventRecordChanged with updated values" do
      event = build_event_course_updated(current_wins: 2, current_losses: 1)
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event = build_event_course_updated(current_wins: 3, current_losses: 1)
      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%EventRecordChanged{wins: 3, losses: 1}] = events
    end

    test "EventRecordChanged copies all fields from snapshot" do
      event =
        build_event_course_updated(
          event_name: "QuickDraft_FDN",
          current_wins: 2,
          current_losses: 1,
          current_module: "Draft",
          card_pool: [91_234, 91_235]
        )

      {:converted, _key, [event_record_changed]} = SnapshotConvert.convert(event, nil)

      assert event_record_changed.event_name == "QuickDraft_FDN"
      assert event_record_changed.wins == 2
      assert event_record_changed.losses == 1
      assert event_record_changed.current_module == "Draft"
      assert event_record_changed.card_pool == [91_234, 91_235]
    end

    test "emitted event copies player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 12:00:00Z]
      event = build_event_course_updated(player_id: "player-abc", occurred_at: occurred_at)
      {:converted, _key, [event_record_changed]} = SnapshotConvert.convert(event, nil)
      assert event_record_changed.player_id == "player-abc"
      assert event_record_changed.occurred_at == occurred_at
    end
  end

  # ── QuestStatus ───────────────────────────────────────────────────────────

  describe "convert/2 QuestStatus" do
    test "returns :unchanged when quest list is identical" do
      event = build_quest_status()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) emits QuestAssigned for each quest" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            },
            %{
              quest_id: "q2",
              goal: 10,
              progress: 0,
              quest_track: "Weekly",
              reward_gold: 1000,
              reward_xp: nil
            }
          ]
        )

      {:converted, _key, events} = SnapshotConvert.convert(event, nil)

      assert length(events) == 2
      quest_ids = Enum.map(events, & &1.quest_id)
      assert "q1" in quest_ids
      assert "q2" in quest_ids
      assert Enum.all?(events, &match?(%QuestAssigned{}, &1))
    end

    test "new quest appearing emits QuestAssigned" do
      event =
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

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

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
            },
            %{
              quest_id: "q2",
              goal: 10,
              progress: 0,
              quest_track: "Weekly",
              reward_gold: 1000,
              reward_xp: nil
            }
          ]
        )

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert Enum.any?(events, &match?(%QuestAssigned{quest_id: "q2"}, &1))
    end

    test "quest disappearing emits QuestCompleted" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            },
            %{
              quest_id: "q2",
              goal: 10,
              progress: 8,
              quest_track: "Weekly",
              reward_gold: 1000,
              reward_xp: nil
            }
          ]
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      # q2 completed and removed
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

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert Enum.any?(events, &match?(%QuestCompleted{quest_id: "q2"}, &1))
    end

    test "quest progress changing emits QuestProgressed" do
      event =
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

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 4,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ]
        )

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%QuestProgressed{quest_id: "q1", new_progress: 4, goal: 5}] = events
    end

    test "events order is QuestCompleted, QuestAssigned, QuestProgressed" do
      event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            },
            %{
              quest_id: "q2",
              goal: 10,
              progress: 8,
              quest_track: "Weekly",
              reward_gold: 1000,
              reward_xp: nil
            }
          ]
        )

      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      # q2 completed, q3 assigned, q1 progressed
      updated_event =
        build_quest_status(
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 3,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            },
            %{
              quest_id: "q3",
              goal: 15,
              progress: 0,
              quest_track: "Weekly",
              reward_gold: 1500,
              reward_xp: nil
            }
          ]
        )

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      event_module_names =
        Enum.map(events, fn e -> e.__struct__ |> Module.split() |> List.last() end)

      completed_idx = Enum.find_index(event_module_names, &(&1 == "QuestCompleted"))
      assigned_idx = Enum.find_index(event_module_names, &(&1 == "QuestAssigned"))
      progressed_idx = Enum.find_index(event_module_names, &(&1 == "QuestProgressed"))

      assert completed_idx < assigned_idx
      assert assigned_idx < progressed_idx
    end

    test "QuestAssigned copies goal and quest_track" do
      event =
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

      {:converted, _key, [assigned]} = SnapshotConvert.convert(event, nil)

      assert assigned.goal == 5
      assert assigned.quest_track == "Daily"
    end

    test "emitted events copy player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 12:00:00Z]

      event =
        build_quest_status(
          player_id: "player-abc",
          quests: [
            %{
              quest_id: "q1",
              goal: 5,
              progress: 2,
              quest_track: "Daily",
              reward_gold: 250,
              reward_xp: nil
            }
          ],
          occurred_at: occurred_at
        )

      {:converted, _key, [assigned]} = SnapshotConvert.convert(event, nil)
      assert assigned.player_id == "player-abc"
      assert assigned.occurred_at == occurred_at
    end
  end

  # ── MasteryProgress ───────────────────────────────────────────────────────

  describe "convert/2 MasteryProgress" do
    test "returns :unchanged when key is identical" do
      event = build_mastery_progress()
      {:converted, key, _events} = SnapshotConvert.convert(event, nil)
      assert SnapshotConvert.convert(event, key) == :unchanged
    end

    test "first sight (nil previous) returns converted with empty events" do
      event = build_mastery_progress()
      assert {:converted, _key, []} = SnapshotConvert.convert(event, nil)
    end

    test "new milestone becoming true emits MasteryMilestoneReached" do
      event = build_mastery_progress(milestone_states: %{"TutorialComplete" => true})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_mastery_progress(milestone_states: %{"TutorialComplete" => true, "Level10" => true})

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%MasteryMilestoneReached{milestone_key: "Level10"}] = events
    end

    test "multiple new milestones emit one event each" do
      event = build_mastery_progress(milestone_states: %{})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_mastery_progress(milestone_states: %{"Level10" => true, "Level20" => true})

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert length(events) == 2
      milestone_keys = Enum.map(events, & &1.milestone_key)
      assert "Level10" in milestone_keys
      assert "Level20" in milestone_keys
    end

    test "false milestone states do not emit events" do
      event = build_mastery_progress(milestone_states: %{})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_mastery_progress(milestone_states: %{"Level10" => false, "Level20" => true})

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert [%MasteryMilestoneReached{milestone_key: "Level20"}] = events
    end

    test "previously true milestone staying true does not re-emit" do
      event = build_mastery_progress(milestone_states: %{"TutorialComplete" => true})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      # Same state, no new milestones
      updated_event =
        build_mastery_progress(
          completed_nodes: 3,
          milestone_states: %{"TutorialComplete" => true}
        )

      {:converted, _new_key, events} = SnapshotConvert.convert(updated_event, key)

      assert events == []
    end

    test "emitted events copy player_id and occurred_at" do
      occurred_at = ~U[2026-01-01 12:00:00Z]
      event = build_mastery_progress(milestone_states: %{"TutorialComplete" => true})
      {:converted, key, _} = SnapshotConvert.convert(event, nil)

      updated_event =
        build_mastery_progress(
          player_id: "player-abc",
          milestone_states: %{"TutorialComplete" => true, "Level10" => true},
          occurred_at: occurred_at
        )

      {:converted, _key, [milestone_reached]} = SnapshotConvert.convert(updated_event, key)
      assert milestone_reached.player_id == "player-abc"
      assert milestone_reached.occurred_at == occurred_at
    end
  end

  # ── Pass-through types ────────────────────────────────────────────────────

  describe "convert/2 pass-through types" do
    test "DeckInventory returns :passthrough" do
      event = build_deck_inventory()
      assert SnapshotConvert.convert(event, nil) == :passthrough
    end

    test "InventorySnapshot returns :passthrough" do
      event = build_inventory_snapshot()
      assert SnapshotConvert.convert(event, nil) == :passthrough
    end

    test "InventoryUpdated returns :passthrough" do
      event = build_inventory_updated()
      assert SnapshotConvert.convert(event, nil) == :passthrough
    end

    test "unknown struct returns :passthrough" do
      event = build_match_created()
      assert SnapshotConvert.convert(event, nil) == :passthrough
    end
  end
end
