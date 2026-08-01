defmodule Scry2.Events.SnapshotDiff do
  @moduledoc """
  Pure-function diff helpers for pass-through snapshot domain events.

  MTGA broadcasts many event types as periodic state dumps even when nothing
  has changed. Most snapshot types are converted to state-change events by
  `Scry2.Events.SnapshotConvert` and never reach this module — it covers only
  the pass-through types that are appended as-is (`DeckInventory`,
  `InventorySnapshot`, `InventoryUpdated`). `changed?/2` extracts a
  semantically meaningful key from the snapshot and compares it against the
  last-known key for that event type.

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
  alias Scry2.Events.Economy.{InventorySnapshot, InventoryUpdated}

  @type diff_key :: term()

  @spec changed?(struct(), diff_key() | nil) :: {:changed, diff_key()} | :unchanged

  # ── Deck ─────────────────────────────────────────────────────────────────

  def changed?(%DeckInventory{} = event, previous_key) do
    key = event.decks |> Enum.map(&{&1.deck_id, &1.name, &1.format}) |> Enum.sort()
    compare(key, previous_key)
  end

  # ── Economy ──────────────────────────────────────────────────────────────

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

  @doc "Returns true if this event type is a pass-through snapshot subject to dedup."
  def snapshot_event?(%DeckInventory{}), do: true
  def snapshot_event?(%InventorySnapshot{}), do: true
  def snapshot_event?(%InventoryUpdated{}), do: true
  def snapshot_event?(_), do: false

  # ── Private ───────────────────────────────────────────────────────────────

  defp compare(key, previous_key) when key == previous_key, do: :unchanged
  defp compare(key, _previous_key), do: {:changed, key}
end
