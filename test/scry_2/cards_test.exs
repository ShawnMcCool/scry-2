defmodule Scry2.CardsTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.TestFactory

  describe "upsert_set!/1" do
    test "creates a new set" do
      set = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns of Ixalan"})

      assert set.code == "LCI"
      assert set.name == "Lost Caverns of Ixalan"
    end

    test "updates an existing set by code (idempotent)" do
      first = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns"})
      second = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns of Ixalan"})

      assert first.id == second.id
      assert second.name == "Lost Caverns of Ixalan"
    end
  end

  describe "upsert_card!/1" do
    test "creates a new card" do
      card =
        Cards.upsert_card!(%{
          lands17_id: 9001,
          arena_id: 91_001,
          name: "Test Card",
          rarity: "rare"
        })

      assert card.lands17_id == 9001
      assert card.arena_id == 91_001
    end

    test "updates an existing card by lands17_id (idempotent per ADR-016)" do
      first = Cards.upsert_card!(%{lands17_id: 9002, name: "Old Name"})
      second = Cards.upsert_card!(%{lands17_id: 9002, name: "New Name"})

      assert first.id == second.id
      assert second.name == "New Name"
    end

    test "never overwrites an existing arena_id (ADR-014 stable key invariant)" do
      _first = Cards.upsert_card!(%{lands17_id: 9003, arena_id: 91_003, name: "First"})

      # Second upsert omits arena_id — existing value must be preserved.
      second = Cards.upsert_card!(%{lands17_id: 9003, name: "Second"})

      assert second.arena_id == 91_003
    end
  end

  describe "get_by_arena_id/1 and get_by_lands17_id/1" do
    test "return nil for unknown ids" do
      assert Cards.get_by_arena_id(99_999_999) == nil
      assert Cards.get_by_lands17_id(99_999_999) == nil
    end

    test "return the card when found" do
      card = TestFactory.create_card(%{lands17_id: 9100, arena_id: 91_100})

      assert Cards.get_by_arena_id(91_100).id == card.id
      assert Cards.get_by_lands17_id(9100).id == card.id
    end
  end

  describe "backfill_arena_id!/2" do
    test "sets arena_id on a card that lacks one" do
      card = TestFactory.create_card(%{lands17_id: 9300, arena_id: nil, name: "Backfill Me"})
      assert card.arena_id == nil

      {:ok, updated} = Cards.backfill_arena_id!(card, 91_300)

      assert updated.arena_id == 91_300
      assert Cards.get_by_arena_id(91_300).id == card.id
    end

    test "no-ops on a card that already has an arena_id (ADR-014)" do
      card = TestFactory.create_card(%{lands17_id: 9301, arena_id: 91_301, name: "Already Set"})

      {:ok, unchanged} = Cards.backfill_arena_id!(card, 99_999)

      assert unchanged.arena_id == 91_301
      assert Cards.get_by_arena_id(91_301).id == card.id
      assert Cards.get_by_arena_id(99_999) == nil
    end
  end

  describe "get_by_name_and_set/2" do
    test "returns cards matching name and set code" do
      set = TestFactory.create_set(%{code: "LCI", name: "Lost Caverns"})
      card = TestFactory.create_card(%{lands17_id: 9400, name: "Dinosaur", set_id: set.id})

      results = Cards.get_by_name_and_set("Dinosaur", "LCI")
      assert length(results) == 1
      assert hd(results).id == card.id
    end

    test "returns empty list when no match" do
      assert Cards.get_by_name_and_set("Nonexistent Card", "ZZZ") == []
    end

    test "does not match wrong set" do
      set = TestFactory.create_set(%{code: "MKM", name: "Murders"})
      TestFactory.create_card(%{lands17_id: 9401, name: "Detective", set_id: set.id})

      assert Cards.get_by_name_and_set("Detective", "LCI") == []
    end
  end

  describe "upsert_scryfall_card!/1" do
    test "creates a new scryfall card" do
      card =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-123",
          name: "Lightning Bolt",
          set_code: "lci",
          rarity: "common",
          raw: %{"id" => "abc-123"}
        })

      assert card.scryfall_id == "abc-123"
      assert card.name == "Lightning Bolt"
    end

    test "updates an existing card by scryfall_id (idempotent)" do
      first =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-456",
          name: "Old Name",
          set_code: "lci",
          raw: %{}
        })

      second =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-456",
          name: "New Name",
          set_code: "lci",
          raw: %{}
        })

      assert first.id == second.id
      assert second.name == "New Name"
    end
  end

  describe "get_scryfall_by_arena_id/1" do
    test "returns the scryfall card for a given arena_id" do
      TestFactory.create_scryfall_card(%{arena_id: 91_500, name: "Found"})
      card = Cards.get_scryfall_by_arena_id(91_500)
      assert card.name == "Found"
    end

    test "returns nil for unknown arena_id" do
      assert Cards.get_scryfall_by_arena_id(99_999_999) == nil
    end
  end

  describe "scryfall_count/0" do
    test "returns the count of scryfall cards" do
      TestFactory.create_scryfall_card(%{name: "Card A"})
      TestFactory.create_scryfall_card(%{name: "Card B"})
      assert Cards.scryfall_count() >= 2
    end
  end

  describe "upsert_mtga_card!/1" do
    test "creates a new MTGA card" do
      card =
        Cards.upsert_mtga_card!(%{
          arena_id: 91_500,
          name: "Test Card",
          expansion_code: "TST",
          collector_number: "42"
        })

      assert card.arena_id == 91_500
      assert card.name == "Test Card"
    end

    test "updates an existing card by arena_id (idempotent)" do
      Cards.upsert_mtga_card!(%{arena_id: 91_501, name: "Old Name"})
      second = Cards.upsert_mtga_card!(%{arena_id: 91_501, name: "New Name"})
      assert second.name == "New Name"
    end
  end

  describe "get_mtga_card/1" do
    test "returns the card for a given arena_id" do
      TestFactory.create_mtga_card(%{arena_id: 91_600, name: "Found"})
      card = Cards.get_mtga_card(91_600)
      assert card.name == "Found"
    end

    test "returns nil for unknown arena_id" do
      assert Cards.get_mtga_card(99_999_999) == nil
    end
  end

  describe "mtga_card_count/0" do
    test "returns the count of MTGA cards" do
      TestFactory.create_mtga_card(%{arena_id: 91_700})
      TestFactory.create_mtga_card(%{arena_id: 91_701})
      assert Cards.mtga_card_count() >= 2
    end
  end

  describe "list_cards/1" do
    setup do
      TestFactory.create_card(%{lands17_id: 9200, name: "Aardvark", rarity: "common"})
      TestFactory.create_card(%{lands17_id: 9201, name: "Zebra", rarity: "mythic"})
      :ok
    end

    test "returns all cards by default" do
      assert length(Cards.list_cards()) >= 2
    end

    test "filters by rarity" do
      mythics = Cards.list_cards(%{rarity: "mythic"})
      assert Enum.all?(mythics, &(&1.rarity == "mythic"))
    end

    test "filters by name substring" do
      results = Cards.list_cards(%{name_like: "ardv"})
      assert Enum.any?(results, &(&1.name == "Aardvark"))
    end
  end

  describe "list_by_arena_ids/1" do
    test "returns 17lands cards indexed by arena_id when found" do
      TestFactory.create_card(%{
        lands17_id: 8001,
        arena_id: 80_001,
        name: "Lightning Bolt",
        types: "Instant"
      })

      result = Cards.list_by_arena_ids([80_001])

      assert Map.has_key?(result, 80_001)
      assert result[80_001].name == "Lightning Bolt"
      assert result[80_001].types == "Instant"
    end

    test "falls back to MtgaCard for arena_ids not in cards_cards" do
      TestFactory.create_mtga_card(%{arena_id: 80_002, name: "Token Creature", types: "2"})

      result = Cards.list_by_arena_ids([80_002])

      assert Map.has_key?(result, 80_002)
      assert result[80_002].name == "Token Creature"
    end

    test "MtgaCard fallback decodes integer types to human-readable strings" do
      # MTGA type enum: 10=Sorcery, 5=Land, 4=Instant, 2=Creature, 1=Artifact, 3=Enchantment, 8=Planeswalker
      TestFactory.create_mtga_card(%{arena_id: 80_003, name: "Fireball", types: "10"})
      TestFactory.create_mtga_card(%{arena_id: 80_004, name: "Forest", types: "5"})
      TestFactory.create_mtga_card(%{arena_id: 80_005, name: "Bolt Instant", types: "4"})
      TestFactory.create_mtga_card(%{arena_id: 80_006, name: "Bear", types: "2"})

      result = Cards.list_by_arena_ids([80_003, 80_004, 80_005, 80_006])

      assert String.contains?(result[80_003].types, "Sorcery")
      assert String.contains?(result[80_004].types, "Land")
      assert String.contains?(result[80_005].types, "Instant")
      assert String.contains?(result[80_006].types, "Creature")
    end

    test "MtgaCard fallback uses stored mana_value" do
      TestFactory.create_mtga_card(%{
        arena_id: 80_007,
        name: "Fallback Card",
        types: "2",
        mana_value: 3
      })

      result = Cards.list_by_arena_ids([80_007])

      assert result[80_007].mana_value == 3
    end

    test "17lands card is preferred over MtgaCard when both exist for the same arena_id" do
      TestFactory.create_card(%{
        lands17_id: 8008,
        arena_id: 80_008,
        name: "Rich Card",
        types: "Creature",
        mana_value: 3
      })

      TestFactory.create_mtga_card(%{arena_id: 80_008, name: "Sparse Card", types: "2"})

      result = Cards.list_by_arena_ids([80_008])

      assert result[80_008].name == "Rich Card"
      assert result[80_008].mana_value == 3
    end

    test "returns empty map for unknown arena_ids" do
      result = Cards.list_by_arena_ids([99_999_999])
      assert result == %{}
    end

    test "filters non-integer arena_ids" do
      result = Cards.list_by_arena_ids([nil, "bad", 1])
      assert result == %{}
    end
  end
end
