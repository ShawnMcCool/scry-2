defmodule Scry2.NetDeckingTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory
  alias Scry2.NetDecking

  test "catalog scores decks against the current snapshot and groups by status" do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    _mountain = create_card(name: "Mountain", rarity: "common")

    create_collection_snapshot(
      entries: [{bolt.arena_id, 4}],
      wildcards_common: 0,
      wildcards_uncommon: 0,
      wildcards_rare: 0,
      wildcards_mythic: 0
    )

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Mono-Red",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    catalog = NetDecking.catalog()

    assert [%{deck: deck, result: %{status: :buildable}}] = catalog.buildable
    assert deck.name == "Mono-Red"
    assert catalog.craftable == []
    assert catalog.short == []
  end

  test "catalog with no snapshot returns decks as fully short" do
    _bolt = create_card(name: "Lightning Bolt", rarity: "rare")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "X",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    catalog = NetDecking.catalog()
    assert [%{result: %{status: :short}}] = catalog.short
  end
end
