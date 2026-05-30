defmodule Scry2.PostDeployTasks.Tasks.BackfillDraftBuildsV1Test do
  use Scry2.DataCase

  import Scry2.TestFactory

  alias Scry2.PostDeployTasks
  alias Scry2.PostDeployTasks.Tasks.BackfillDraftBuildsV1

  test "is registered" do
    assert BackfillDraftBuildsV1 in PostDeployTasks.registered_tasks()
  end

  test "run/0 backfills existing draft decks and returns :ok" do
    draft = create_deck(%{mtga_deck_id: "draft:QuickDraft_SOS_20260430", current_main_deck: %{}})

    Scry2.Decks.upsert_game_submission!(%{
      mtga_deck_id: draft.mtga_deck_id,
      mtga_match_id: "m1",
      game_number: 1,
      main_deck: %{"cards" => [%{"arena_id" => 10, "count" => 2}]},
      sideboard: %{"cards" => []},
      submitted_at: ~U[2026-04-30 12:00:00Z]
    })

    assert BackfillDraftBuildsV1.run() == :ok

    assert Scry2.Decks.get_deck(draft.mtga_deck_id).current_main_deck ==
             %{"cards" => [%{"arena_id" => 10, "count" => 2}]}
  end

  test "run/0 is idempotent — re-running leaves the deck unchanged" do
    draft = create_deck(%{mtga_deck_id: "draft:QuickDraft_SOS_20260430", current_main_deck: %{}})

    Scry2.Decks.upsert_game_submission!(%{
      mtga_deck_id: draft.mtga_deck_id,
      mtga_match_id: "m1",
      game_number: 1,
      main_deck: %{"cards" => [%{"arena_id" => 10, "count" => 2}]},
      sideboard: %{"cards" => []},
      submitted_at: ~U[2026-04-30 12:00:00Z]
    })

    assert BackfillDraftBuildsV1.run() == :ok
    deck_after_first_run = Scry2.Decks.get_deck(draft.mtga_deck_id).current_main_deck

    assert BackfillDraftBuildsV1.run() == :ok
    deck_after_second_run = Scry2.Decks.get_deck(draft.mtga_deck_id).current_main_deck

    assert deck_after_second_run == deck_after_first_run
  end
end
