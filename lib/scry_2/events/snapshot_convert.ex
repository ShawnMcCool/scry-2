defmodule Scry2.Events.SnapshotConvert do
  @moduledoc """
  Pure-function converter for snapshot domain events.

  MTGA snapshot events represent periodic state dumps — rank, quests, daily
  wins, mastery, collection, event courses. `SnapshotConvert` handles both the
  diff check and the semantic conversion in a single pass:

  1. Extracts a diff key from the snapshot.
  2. Compares it against `previous_key` (from `state.snapshot_state[slug]`).
  3. If unchanged: returns `:unchanged` — caller skips the event.
  4. If changed (or first sight): returns `{:converted, new_key, [events]}`.
     The caller appends the converted events instead of the snapshot itself.
     `new_key` is stored back into `snapshot_state` for the next comparison.
  5. For pass-through snapshot types: returns `:passthrough` — caller falls
     through to `SnapshotDiff` dedup logic unchanged.

  ## Pass-through types

  `DeckInventory`, `InventorySnapshot`, and `InventoryUpdated` are kept as-is
  and appended directly. They have no meaningful conversion to state-change
  events at this stage.

  ## Pipeline stage

      RawEvent
        → IdentifyDomainEvents  (produce snapshot struct)
        → SnapshotConvert        (diff + convert to state-change events)
        → Events.append!         (persist converted events)

  ## Return values

  - `{:converted, new_key, events}` — snapshot changed; append `events`.
    `events` may be empty (e.g. first sight of `DailyWinsStatus`).
  - `:unchanged` — no state change; skip.
  - `:passthrough` — not a convertible type; use `SnapshotDiff` instead.
  """

  alias Scry2.Events.Deck.DeckInventory

  alias Scry2.Events.Economy.{
    CardsAcquired,
    CardsRemoved,
    CollectionUpdated,
    InventorySnapshot,
    InventoryUpdated
  }

  alias Scry2.Events.Event.{EventCourseUpdated, EventRecordChanged}

  alias Scry2.Events.Progression.{
    DailyWinEarned,
    DailyWinsStatus,
    MasteryMilestoneReached,
    MasteryProgress,
    QuestAssigned,
    QuestCompleted,
    QuestProgressed,
    QuestStatus,
    RankAdvanced,
    RankMatchRecorded,
    RankSnapshot,
    WeeklyWinEarned
  }

  @type diff_key :: term()

  @spec convert(struct(), diff_key() | nil) ::
          {:converted, new_key :: diff_key(), [struct()]} | :unchanged | :passthrough

  # ── RankSnapshot ──────────────────────────────────────────────────────────

  def convert(%RankSnapshot{} = event, previous_key) do
    key = {
      event.constructed_class,
      event.constructed_level,
      event.constructed_step,
      event.constructed_matches_won,
      event.constructed_matches_lost,
      event.limited_class,
      event.limited_level,
      event.limited_step,
      event.limited_matches_won,
      event.limited_matches_lost,
      event.season_ordinal
    }

    if key == previous_key do
      :unchanged
    else
      {:converted, key, rank_events(event, previous_key)}
    end
  end

  # ── DailyWinsStatus ───────────────────────────────────────────────────────

  def convert(%DailyWinsStatus{} = event, previous_key) do
    key = {event.daily_position, event.weekly_position}

    if key == previous_key do
      :unchanged
    else
      {:converted, key, daily_wins_events(event, previous_key)}
    end
  end

  # ── CollectionUpdated ─────────────────────────────────────────────────────

  def convert(%CollectionUpdated{} = event, previous_key) do
    if event.card_counts == previous_key do
      :unchanged
    else
      {:converted, event.card_counts, collection_events(event, previous_key)}
    end
  end

  # ── EventCourseUpdated ────────────────────────────────────────────────────

  def convert(%EventCourseUpdated{} = event, previous_key) do
    key =
      {event.event_name, event.current_wins, event.current_losses, event.current_module,
       event.card_pool}

    if key == previous_key do
      :unchanged
    else
      event_record_changed = %EventRecordChanged{
        event_name: event.event_name,
        wins: event.current_wins,
        losses: event.current_losses,
        current_module: event.current_module,
        card_pool: event.card_pool,
        player_id: event.player_id,
        occurred_at: event.occurred_at
      }

      {:converted, key, [event_record_changed]}
    end
  end

  # ── QuestStatus ───────────────────────────────────────────────────────────

  def convert(%QuestStatus{} = event, previous_key) do
    key =
      Enum.map(event.quests, fn quest ->
        {quest.quest_id, quest.goal, quest.progress, quest.quest_track}
      end)

    if key == previous_key do
      :unchanged
    else
      {:converted, key, quest_events(event, previous_key)}
    end
  end

  # ── MasteryProgress ───────────────────────────────────────────────────────

  def convert(%MasteryProgress{} = event, previous_key) do
    key = {event.completed_nodes, event.milestone_states}

    if key == previous_key do
      :unchanged
    else
      {:converted, key, mastery_events(event, previous_key)}
    end
  end

  # ── Pass-through types ────────────────────────────────────────────────────

  def convert(%DeckInventory{}, _previous_key), do: :passthrough
  def convert(%InventorySnapshot{}, _previous_key), do: :passthrough
  def convert(%InventoryUpdated{}, _previous_key), do: :passthrough
  def convert(_event, _previous_key), do: :passthrough

  # ── Private: rank conversion ───────────────────────────────────────────────

  defp rank_events(event, previous_key) do
    rank_advanced = %RankAdvanced{
      player_id: event.player_id,
      constructed_class: event.constructed_class,
      constructed_level: event.constructed_level,
      constructed_step: event.constructed_step,
      constructed_matches_won: event.constructed_matches_won,
      constructed_matches_lost: event.constructed_matches_lost,
      constructed_percentile: event.constructed_percentile,
      constructed_leaderboard_placement: event.constructed_leaderboard_placement,
      limited_class: event.limited_class,
      limited_level: event.limited_level,
      limited_step: event.limited_step,
      limited_matches_won: event.limited_matches_won,
      limited_matches_lost: event.limited_matches_lost,
      limited_percentile: event.limited_percentile,
      limited_leaderboard_placement: event.limited_leaderboard_placement,
      season_ordinal: event.season_ordinal,
      occurred_at: event.occurred_at
    }

    match_records = rank_match_records(event, previous_key)
    [rank_advanced | match_records]
  end

  defp rank_match_records(_event, nil), do: []

  defp rank_match_records(event, previous_key) do
    {_pc_class, _pc_level, _pc_step, pc_won, pc_lost, _pl_class, _pl_level, _pl_step, pl_won,
     pl_lost, _season} = previous_key

    constructed_record =
      if {event.constructed_matches_won, event.constructed_matches_lost} != {pc_won, pc_lost} do
        %RankMatchRecorded{
          player_id: event.player_id,
          format: :constructed,
          won: event.constructed_matches_won > pc_won,
          wins: event.constructed_matches_won,
          losses: event.constructed_matches_lost,
          occurred_at: event.occurred_at
        }
      end

    limited_record =
      if {event.limited_matches_won, event.limited_matches_lost} != {pl_won, pl_lost} do
        %RankMatchRecorded{
          player_id: event.player_id,
          format: :limited,
          won: event.limited_matches_won > pl_won,
          wins: event.limited_matches_won,
          losses: event.limited_matches_lost,
          occurred_at: event.occurred_at
        }
      end

    [constructed_record, limited_record] |> Enum.reject(&is_nil/1)
  end

  # ── Private: daily wins conversion ────────────────────────────────────────

  defp daily_wins_events(_event, nil), do: []

  defp daily_wins_events(event, {prev_daily, prev_weekly}) do
    daily_event =
      if event.daily_position > prev_daily do
        %DailyWinEarned{
          player_id: event.player_id,
          new_position: event.daily_position,
          occurred_at: event.occurred_at
        }
      end

    weekly_event =
      if event.weekly_position > prev_weekly do
        %WeeklyWinEarned{
          player_id: event.player_id,
          new_position: event.weekly_position,
          occurred_at: event.occurred_at
        }
      end

    [daily_event, weekly_event] |> Enum.reject(&is_nil/1)
  end

  # ── Private: collection conversion ────────────────────────────────────────

  defp collection_events(event, nil) do
    [
      %CardsAcquired{
        player_id: event.player_id,
        cards: event.card_counts,
        occurred_at: event.occurred_at
      }
    ]
  end

  defp collection_events(event, previous_card_counts) do
    acquired =
      Enum.reduce(event.card_counts, %{}, fn {arena_id, new_count}, acc ->
        old_count = Map.get(previous_card_counts, arena_id, 0)
        if new_count > old_count, do: Map.put(acc, arena_id, new_count - old_count), else: acc
      end)

    removed =
      Enum.reduce(previous_card_counts, %{}, fn {arena_id, old_count}, acc ->
        new_count = Map.get(event.card_counts, arena_id, 0)
        if new_count < old_count, do: Map.put(acc, arena_id, old_count - new_count), else: acc
      end)

    acquired_event =
      if map_size(acquired) > 0 do
        %CardsAcquired{
          player_id: event.player_id,
          cards: acquired,
          occurred_at: event.occurred_at
        }
      end

    removed_event =
      if map_size(removed) > 0 do
        %CardsRemoved{
          player_id: event.player_id,
          cards: removed,
          occurred_at: event.occurred_at
        }
      end

    [acquired_event, removed_event] |> Enum.reject(&is_nil/1)
  end

  # ── Private: quest conversion ─────────────────────────────────────────────

  defp quest_events(event, nil) do
    Enum.map(event.quests, fn quest ->
      %QuestAssigned{
        player_id: event.player_id,
        quest_id: quest.quest_id,
        goal: quest.goal,
        quest_track: quest.quest_track,
        occurred_at: event.occurred_at
      }
    end)
  end

  defp quest_events(event, previous_key) do
    prev_quest_ids =
      MapSet.new(previous_key, fn {quest_id, _goal, _progress, _track} -> quest_id end)

    prev_quests_by_id =
      Map.new(previous_key, fn {quest_id, goal, progress, track} ->
        {quest_id, %{quest_id: quest_id, goal: goal, progress: progress, quest_track: track}}
      end)

    current_quests_by_id = Map.new(event.quests, fn quest -> {quest.quest_id, quest} end)
    current_quest_ids = MapSet.new(Map.keys(current_quests_by_id))

    completed_events =
      prev_quest_ids
      |> MapSet.difference(current_quest_ids)
      |> Enum.map(fn quest_id ->
        %QuestCompleted{
          player_id: event.player_id,
          quest_id: quest_id,
          occurred_at: event.occurred_at
        }
      end)

    assigned_events =
      current_quest_ids
      |> MapSet.difference(prev_quest_ids)
      |> Enum.map(fn quest_id ->
        quest = Map.fetch!(current_quests_by_id, quest_id)

        %QuestAssigned{
          player_id: event.player_id,
          quest_id: quest_id,
          goal: quest.goal,
          quest_track: quest.quest_track,
          occurred_at: event.occurred_at
        }
      end)

    progressed_events =
      current_quest_ids
      |> MapSet.intersection(prev_quest_ids)
      |> Enum.flat_map(fn quest_id ->
        current = Map.fetch!(current_quests_by_id, quest_id)
        previous = Map.fetch!(prev_quests_by_id, quest_id)

        if current.progress != previous.progress do
          [
            %QuestProgressed{
              player_id: event.player_id,
              quest_id: quest_id,
              new_progress: current.progress,
              goal: current.goal,
              occurred_at: event.occurred_at
            }
          ]
        else
          []
        end
      end)

    completed_events ++ assigned_events ++ progressed_events
  end

  # ── Private: mastery conversion ───────────────────────────────────────────

  defp mastery_events(_event, nil), do: []

  defp mastery_events(event, {_prev_completed, prev_milestone_states}) do
    (event.milestone_states || %{})
    |> Enum.flat_map(fn {milestone_key, value} ->
      old_value = Map.get(prev_milestone_states || %{}, milestone_key, false)

      if value == true and old_value != true do
        [
          %MasteryMilestoneReached{
            player_id: event.player_id,
            milestone_key: milestone_key,
            occurred_at: event.occurred_at
          }
        ]
      else
        []
      end
    end)
  end
end
