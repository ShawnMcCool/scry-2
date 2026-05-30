defmodule Scry2.PostDeployTasks.Tasks.BackfillDraftBuildsV1 do
  @moduledoc """
  Backfills `current_main_deck` / `current_sideboard` on existing draft
  decks from their latest game submission.

  Draft/limited decks never receive a `DeckUpdated` event, so before the
  deck-library change their card list stayed empty on the deck row even
  though the cards were saved in `decks_game_submissions`. The projection
  now stamps the final build for *new* submissions; this task catches up
  draft decks already in the database on first boot after the upgrade.

  Delegates to `Scry2.Decks.backfill_draft_builds!/0`, which is idempotent
  and touches only the card-list columns — never `starred`, `archived`, or
  any other table — so re-running from the Operations UI is safe.
  """

  @behaviour Scry2.PostDeployTasks.Task

  require Scry2.Log, as: Log

  @impl true
  def task_id, do: "decks.backfill_draft_builds_v1"

  @impl true
  def description do
    "Populate existing draft decks' card lists from their saved game " <>
      "submissions. Required after upgrading to the deck-library release so " <>
      "draft decks show their cards and become re-importable to MTGA."
  end

  @impl true
  def run do
    count = Scry2.Decks.backfill_draft_builds!()
    Log.info(:ingester, "post-deploy: backfilled #{count} draft deck build(s)")
    :ok
  end
end
