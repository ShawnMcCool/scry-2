defmodule Scry2.Events.SnapshotDiff do
  @moduledoc """
  Pure-function diff helpers for snapshot domain events.

  MTGA broadcasts many event types as periodic state dumps — rank info,
  quest status, inventory, deck lists — even when nothing has changed.
  `changed?/2` extracts a semantically meaningful key from each snapshot
  event and compares it against the last-known key for that event type.

  ## Usage

      previous_key = load_last_diff_key(event_type)

      case SnapshotDiff.changed?(event, previous_key) do
        {:changed, new_key} -> append event, persist new_key
        :unchanged           -> skip
      end

  ## Key design

  Each clause extracts the fields that represent meaningful state change,
  **excluding `player_id` and `occurred_at`** (those differ on every
  broadcast). The key is whatever is cheapest to compare for that type —
  a tuple for scalar fields, a list for ordered collections, or the raw
  value when the whole payload is the key.
  """

  alias Scry2.Events.Deck.DeckInventory
  alias Scry2.Events.Economy.{CollectionUpdated, InventorySnapshot, InventoryUpdated}
  alias Scry2.Events.Event.EventCourseUpdated
  alias Scry2.Events.Progression.{DailyWinsStatus, MasteryProgress, QuestStatus, RankSnapshot}

  @type diff_key :: term()

  @spec changed?(struct(), diff_key() | nil) :: {:changed, diff_key()} | :unchanged

  # ── Progression ──────────────────────────────────────────────────────────

  def changed?(%RankSnapshot{} = event, previous_key) do
    key =
      {event.constructed_class, event.constructed_level, event.constructed_step,
       event.constructed_matches_won, event.constructed_matches_lost, event.limited_class,
       event.limited_level, event.limited_step, event.limited_matches_won,
       event.limited_matches_lost, event.season_ordinal}

    compare(key, previous_key)
  end

  def changed?(%QuestStatus{} = event, previous_key) do
    # reward_gold and reward_xp are static reward descriptions — they don't change on an existing quest
    key =
      Enum.map(event.quests, fn quest ->
        {quest.quest_id, quest.goal, quest.progress, quest.quest_track}
      end)

    compare(key, previous_key)
  end

  def changed?(%DailyWinsStatus{} = event, previous_key) do
    key = {event.daily_position, event.weekly_position}
    compare(key, previous_key)
  end

  def changed?(%MasteryProgress{} = event, previous_key) do
    # node_states can be large; completed_nodes + milestone_states captures all meaningful progression changes
    key = {event.completed_nodes, event.milestone_states}
    compare(key, previous_key)
  end

  # ── Deck ─────────────────────────────────────────────────────────────────

  def changed?(%DeckInventory{} = event, previous_key) do
    key = event.decks |> Enum.map(& &1.deck_id) |> Enum.sort()
    compare(key, previous_key)
  end

  # ── Economy ──────────────────────────────────────────────────────────────

  def changed?(%CollectionUpdated{} = event, previous_key) do
    compare(event.card_counts, previous_key)
  end

  def changed?(%InventorySnapshot{} = event, previous_key) do
    key =
      {event.gold, event.gems, event.wildcards_common, event.wildcards_uncommon,
       event.wildcards_rare, event.wildcards_mythic, event.vault_progress, event.draft_tokens,
       event.sealed_tokens, event.boosters}

    compare(key, previous_key)
  end

  def changed?(%InventoryUpdated{} = event, previous_key) do
    key =
      {event.gold, event.gems, event.wildcards_common, event.wildcards_uncommon,
       event.wildcards_rare, event.wildcards_mythic, event.vault_progress, event.draft_tokens,
       event.sealed_tokens}

    compare(key, previous_key)
  end

  # ── Event ─────────────────────────────────────────────────────────────────

  def changed?(%EventCourseUpdated{} = event, previous_key) do
    key =
      {event.event_name, event.current_wins, event.current_losses, event.current_module,
       event.card_pool}

    compare(key, previous_key)
  end

  @doc "Returns true if this event type is a snapshot event subject to dedup."
  def snapshot_event?(%RankSnapshot{}), do: true
  def snapshot_event?(%QuestStatus{}), do: true
  def snapshot_event?(%DailyWinsStatus{}), do: true
  def snapshot_event?(%MasteryProgress{}), do: true
  def snapshot_event?(%DeckInventory{}), do: true
  def snapshot_event?(%CollectionUpdated{}), do: true
  def snapshot_event?(%InventorySnapshot{}), do: true
  def snapshot_event?(%InventoryUpdated{}), do: true
  def snapshot_event?(%EventCourseUpdated{}), do: true
  def snapshot_event?(_), do: false

  # ── Private ───────────────────────────────────────────────────────────────

  defp compare(key, previous_key) when key == previous_key, do: :unchanged
  defp compare(key, _previous_key), do: {:changed, key}
end
