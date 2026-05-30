defmodule Scry2.PostDeployTasks.Tasks.BackfillInventoryDecksV1 do
  @moduledoc """
  Upserts the player's full deck collection into `decks_decks` from the most
  recent `deck_inventory` domain event.

  Before the durable-deck-records change, only decks the player played or
  edited while Scry2 was watching appeared on `/decks`; the rest of the
  collection was captured in the event log but never projected. The projection
  now handles `deck_inventory` for *new* snapshots; this task catches up the
  collection already in the event store on first boot after the upgrade.

  Delegates to `Scry2.Decks.backfill_inventory_decks!/0`, which is idempotent
  and touches only `current_name`/`format` per row — never `starred`,
  `archived`, card lists, or any other table — so re-running from the
  Operations UI is safe.
  """

  @behaviour Scry2.PostDeployTasks.Task

  require Scry2.Log, as: Log

  @impl true
  def task_id, do: "decks.backfill_inventory_decks_v1"

  @impl true
  def description do
    "Populate every deck in your MTGA collection as a durable record from the " <>
      "captured deck-inventory snapshot. Required after upgrading to the " <>
      "durable-deck-records release so your full deck list appears on /decks."
  end

  @impl true
  def run do
    count = Scry2.Decks.backfill_inventory_decks!()
    Log.info(:ingester, "post-deploy: backfilled #{count} inventory deck(s)")
    :ok
  end
end
