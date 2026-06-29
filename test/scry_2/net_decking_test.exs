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

  test "deck_detail returns per-card owned/missing rows, balances, and export text" do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    _mountain = create_card(name: "Mountain", rarity: "common")

    create_collection_snapshot(
      entries: [{bolt.arena_id, 2}],
      wildcards_common: 0,
      wildcards_uncommon: 0,
      wildcards_rare: 5,
      wildcards_mythic: 0
    )

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "Mono-Red",
        archetype: "Aggro",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    detail = NetDecking.deck_detail(deck)

    # Own 2 of 4 rare Bolts, 5 rare wildcards on hand → craftable
    assert detail.result.status == :craftable
    assert detail.wildcards.rare == 5

    bolt_row = Enum.find(detail.main_rows, &(&1.arena_id == bolt.arena_id))
    assert bolt_row.needed == 4
    assert bolt_row.owned == 2
    assert bolt_row.missing == 2
    assert bolt_row.rarity == "rare"
    refute bolt_row.free?

    mountain_row = Enum.find(detail.main_rows, &(&1.name == "Mountain"))
    assert mountain_row.free?
    assert mountain_row.missing == 0

    assert detail.export_text =~ "Lightning Bolt"
  end

  test "deck_detail counts a card owned under a different printing as owned" do
    # Two printings of one card share a name; the deck resolves to one, the
    # player owns the other. Name-identity ownership must still count it.
    printing_a = create_card(name: "Roaring Furnace", rarity: "rare")
    printing_b = create_card(name: "Roaring Furnace", rarity: "rare")

    {:ok, deck} =
      NetDecking.import_decklist(%{
        name: "DFC Test",
        source_name: "manual",
        decklist_text: "Deck\n4 Roaring Furnace\n"
      })

    [%{"arena_id" => resolved_id}] = deck.main_deck["cards"]

    other_id =
      Enum.find([printing_a.arena_id, printing_b.arena_id], &(&1 != resolved_id))

    create_collection_snapshot(entries: [{other_id, 4}])

    detail = NetDecking.deck_detail(deck)
    row = Enum.find(detail.main_rows, &(&1.name == "Roaring Furnace"))

    assert row.owned == 4
    assert row.missing == 0
  end

  test "source_status summarizes decks per source with counts and latest fetch" do
    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "A",
        source_name: "mtgo",
        decklist_text: "Deck\n1 Alpha\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "B",
        source_name: "mtgo",
        decklist_text: "Deck\n1 Beta\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "C",
        source_name: "local",
        decklist_text: "Deck\n1 Gamma\n"
      })

    status = NetDecking.source_status()

    assert [
             %{source_name: "local", count: 1},
             %{source_name: "mtgo", count: 2}
           ] = status

    assert Enum.all?(status, &match?(%DateTime{}, &1.latest))
  end

  test "catalog collapses near-identical decks into one representative with a count" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Goblin Raider", rarity: "common", color_identity: "R")
    create_card(name: "Shock Bolt", rarity: "common", color_identity: "R")
    create_card(name: "Grizzly Bear", rarity: "rare", color_identity: "G")

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Red A",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Red B",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n1 Grizzly Bear\n"
      })

    {:ok, _} =
      NetDecking.import_decklist(%{
        name: "Bears",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Grizzly Bear\n"
      })

    catalog = NetDecking.catalog()
    entries = catalog.buildable ++ catalog.craftable ++ catalog.short

    # Red A + Red B share 3/4 nonland cards (Jaccard 0.75 >= 0.7) -> one entry, count 2.
    red = Enum.find(entries, &(&1.variant_count == 2))
    assert red
    assert red.color_identity == "R"
    assert red.label =~ "Mono-Red"
    assert Enum.any?(entries, &(&1.variant_count == 1))
  end
end
