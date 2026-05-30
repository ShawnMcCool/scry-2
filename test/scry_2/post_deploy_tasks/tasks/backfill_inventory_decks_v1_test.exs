defmodule Scry2.PostDeployTasks.Tasks.BackfillInventoryDecksV1Test do
  use Scry2.DataCase

  import Scry2.TestFactory

  alias Scry2.PostDeployTasks
  alias Scry2.PostDeployTasks.Tasks.BackfillInventoryDecksV1

  test "is registered" do
    assert BackfillInventoryDecksV1 in PostDeployTasks.registered_tasks()
  end

  test "task_id/0 returns the expected identifier" do
    assert BackfillInventoryDecksV1.task_id() == "decks.backfill_inventory_decks_v1"
  end

  test "run/0 upserts decks from the most recent deck_inventory event and returns :ok" do
    create_domain_event(
      build_deck_inventory(
        decks: [
          %{deck_id: "deck-aaa-111", name: "Azorius Control", format: "Standard"},
          %{deck_id: "deck-bbb-222", name: "Draft Deck", format: "Limited"}
        ]
      )
    )

    assert BackfillInventoryDecksV1.run() == :ok

    assert Scry2.Decks.get_deck("deck-aaa-111").current_name == "Azorius Control"
    assert Scry2.Decks.get_deck("deck-bbb-222").current_name == "Draft Deck"
  end

  test "run/0 returns :ok when no deck_inventory event exists" do
    assert BackfillInventoryDecksV1.run() == :ok
  end
end
