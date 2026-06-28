defmodule Scry2.NetDecking.IngestDecklistTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory
  alias Scry2.NetDecking.{Deck, IngestDecklist}
  alias Scry2.Repo

  defp seed_cards do
    create_card(name: "Lightning Bolt", rarity: "rare")
    create_card(name: "Mountain", rarity: "common")
  end

  test "ingests a pasted decklist into the corpus" do
    seed_cards()

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Mono-Red",
        archetype: "Aggro",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    assert %Deck{name: "Mono-Red", format: "Standard", source_name: "manual"} = deck
    assert length(deck.main_deck["cards"]) == 2
    assert deck.unresolved_cards["cards"] == []
    assert is_integer(deck.composition_hash)
  end

  test "records unresolved cards instead of dropping them" do
    create_card(name: "Mountain", rarity: "common")

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Partial",
        source_name: "manual",
        decklist_text: "Deck\n4 Made Up Card (XYZ) 1\n16 Mountain\n"
      })

    assert length(deck.main_deck["cards"]) == 1
    assert [%{"name" => "Made Up Card"}] = deck.unresolved_cards["cards"]
  end

  test "re-ingesting an all-unresolved list deduplicates (no cards seeded)" do
    attrs = %{
      name: "Ghost Deck",
      source_name: "manual",
      decklist_text: "Deck\n4 Completely Made Up Card (XYZ) 99\n"
    }

    {:ok, first} = IngestDecklist.run(attrs)
    {:ok, second} = IngestDecklist.run(attrs)

    assert first.id == second.id
    assert Repo.aggregate(Deck, :count) == 1
  end

  test "re-ingesting the same list updates in place (idempotent)" do
    seed_cards()

    attrs = %{
      name: "Mono-Red",
      source_name: "manual",
      decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
    }

    {:ok, first} = IngestDecklist.run(attrs)
    {:ok, second} = IngestDecklist.run(attrs)

    assert first.id == second.id
    assert Repo.aggregate(Deck, :count) == 1
  end
end
