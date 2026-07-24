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

  test "merges a card split across two decklist lines into one summed entry" do
    seed_cards()

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Split Lines",
        source_name: "mtgo",
        decklist_text: "Deck\n1 Lightning Bolt\n3 Lightning Bolt\n16 Mountain\n"
      })

    assert deck.main_deck["cards"]
           |> Enum.filter(&(&1["arena_id"] == card_arena_id("Lightning Bolt")))
           |> length() == 1

    assert %{"count" => 4} =
             Enum.find(
               deck.main_deck["cards"],
               &(&1["arena_id"] == card_arena_id("Lightning Bolt"))
             )
  end

  defp card_arena_id(name) do
    Scry2.Cards.resolve_references([
      %{name: name, set_code: nil, collector_number: nil, count: 1}
    ]).resolved
    |> hd()
    |> Map.fetch!(:arena_id)
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

  test "persists competitive provenance when the source provides it" do
    seed_cards()

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Standard Challenge 32 — Venom01",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n",
        pilot: "Venom01",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-06-26],
        placement: 1,
        swiss_rank: 3,
        field_size: 42,
        wins: 7,
        losses: 2
      })

    assert deck.pilot == "Venom01"
    assert deck.event_name == "Standard Challenge 32"
    assert deck.event_date == ~D[2026-06-26]
    assert deck.placement == 1
    assert deck.swiss_rank == 3
    assert deck.field_size == 42
    assert deck.wins == 7
    assert deck.losses == 2
  end

  test "provenance stays nil for sources without it" do
    seed_cards()

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Pasted",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    assert deck.pilot == nil
    assert deck.placement == nil
    assert deck.event_date == nil
  end

  test "the same maindeck in two different formats does not collide" do
    seed_cards()

    {:ok, standard_deck} =
      IngestDecklist.run(%{
        name: "Mono-Red Standard",
        source_name: "manual",
        format: "Standard",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    {:ok, modern_deck} =
      IngestDecklist.run(%{
        name: "Mono-Red Modern",
        source_name: "manual",
        format: "Modern",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    assert standard_deck.id != modern_deck.id
    assert standard_deck.format == "Standard"
    assert modern_deck.format == "Modern"
    assert Repo.aggregate(Deck, :count) == 2
  end

  describe "reingest/2" do
    test "re-resolves an existing deck in place after the card data improves" do
      create_card(name: "Mountain", rarity: "common")

      attrs = %{
        name: "Improves Later",
        source_name: "mtgo",
        pilot: "venom01",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      }

      {:ok, stale} = IngestDecklist.run(attrs)
      assert [%{"name" => "Lightning Bolt"}] = stale.unresolved_cards["cards"]
      assert length(stale.main_deck["cards"]) == 1

      # Card data now covers the missing card.
      create_card(name: "Lightning Bolt", rarity: "rare")

      {:ok, fixed} = IngestDecklist.reingest(stale, attrs)

      assert fixed.id == stale.id
      assert fixed.unresolved_cards["cards"] == []
      assert length(fixed.main_deck["cards"]) == 2
      assert fixed.composition_hash != stale.composition_hash
      assert Repo.aggregate(Deck, :count) == 1
    end

    test "does not spawn a duplicate even though the composition hash changed" do
      create_card(name: "Mountain", rarity: "common")

      attrs = %{
        name: "No Dup",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      }

      {:ok, stale} = IngestDecklist.run(attrs)
      create_card(name: "Lightning Bolt", rarity: "rare")
      {:ok, _fixed} = IngestDecklist.reingest(stale, attrs)

      assert Repo.aggregate(Deck, :count) == 1
    end
  end

  describe "archetype stamping" do
    defp install_burn_definition do
      Scry2.Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "Burn",
            kind: "archetype",
            name: "Burn",
            include_color_in_name: true,
            conditions: [%{"type" => "InMainboard", "cards" => ["Lightning Bolt"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })
    end

    test "stamps the classified archetype at ingest" do
      install_burn_definition()
      create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
      create_card(name: "Mountain", rarity: "common", color_identity: "R", is_land: true)

      {:ok, deck} =
        IngestDecklist.run(%{
          name: "Standard Challenge — pilot",
          source_name: "mtgo",
          decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
        })

      assert deck.archetype_name == "Mono-Red Burn"
      assert deck.archetype_variant == nil
      assert deck.archetype_fallback == false
    end

    test "leaves the stamp nil when classification is unknown" do
      Scry2.Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "Never",
            kind: "archetype",
            name: "Never",
            include_color_in_name: false,
            conditions: [%{"type" => "InMainboard", "cards" => ["Nonexistent Card"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })

      create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

      {:ok, deck} =
        IngestDecklist.run(%{
          name: "Unmatched",
          source_name: "manual",
          decklist_text: "Deck\n4 Lightning Bolt\n"
        })

      assert deck.archetype_name == nil
      assert deck.archetype_fallback == false
    end

    test "re-ingesting refreshes the stamp" do
      create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

      attrs = %{
        name: "Restamped",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      }

      {:ok, first} = IngestDecklist.run(attrs)
      assert first.archetype_name == nil

      install_burn_definition()

      # No lands in this list, so no color prefix — just the bare name.
      {:ok, second} = IngestDecklist.run(attrs)
      assert second.id == first.id
      assert second.archetype_name == "Burn"
    end
  end
end
