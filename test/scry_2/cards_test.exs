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

    test "filters by rarity list" do
      results = Cards.list_cards(%{rarity: ["common", "mythic"]})
      rarities = Enum.map(results, & &1.rarity) |> Enum.uniq() |> Enum.sort()
      assert "common" in rarities
      assert "mythic" in rarities
      refute "rare" in rarities
    end

    test "filters by name substring" do
      results = Cards.list_cards(%{name_like: "ardv"})
      assert Enum.any?(results, &(&1.name == "Aardvark"))
    end
  end

  describe "list_cards/1 — color filters" do
    setup do
      TestFactory.create_card(%{
        lands17_id: 9500,
        name: "Red Card",
        color_identity: "R"
      })

      TestFactory.create_card(%{
        lands17_id: 9501,
        name: "Blue Card",
        color_identity: "U"
      })

      TestFactory.create_card(%{
        lands17_id: 9502,
        name: "Izzet Card",
        color_identity: "UR"
      })

      TestFactory.create_card(%{
        lands17_id: 9503,
        name: "Colorless Card",
        color_identity: ""
      })

      :ok
    end

    test "single color filter returns matching cards" do
      results = Cards.list_cards(%{colors: MapSet.new(["R"])})
      names = Enum.map(results, & &1.name)
      assert "Red Card" in names
      assert "Izzet Card" in names
      refute "Blue Card" in names
    end

    test "two color filters use OR semantics (union)" do
      results = Cards.list_cards(%{colors: MapSet.new(["R", "U"])})
      names = Enum.map(results, & &1.name)
      assert "Red Card" in names
      assert "Blue Card" in names
      assert "Izzet Card" in names
    end

    test "M filter returns only multicolor cards" do
      results = Cards.list_cards(%{colors: MapSet.new(["M"])})
      names = Enum.map(results, & &1.name)
      assert "Izzet Card" in names
      refute "Red Card" in names
      refute "Colorless Card" in names
    end

    test "C filter returns only colorless cards" do
      results = Cards.list_cards(%{colors: MapSet.new(["C"])})
      names = Enum.map(results, & &1.name)
      assert "Colorless Card" in names
      refute "Red Card" in names
    end

    test "empty color filter returns all cards" do
      results = Cards.list_cards(%{colors: MapSet.new()})
      assert length(results) >= 4
    end
  end

  describe "list_cards/1 — type filters" do
    setup do
      TestFactory.create_card(%{
        lands17_id: 9600,
        name: "Lightning Bolt",
        types: "Instant",
        is_instant: true
      })

      TestFactory.create_card(%{
        lands17_id: 9601,
        name: "Llanowar Elves",
        types: "Creature Elf Druid",
        is_creature: true
      })

      TestFactory.create_card(%{
        lands17_id: 9602,
        name: "Forest",
        types: "Basic Land Forest",
        is_land: true
      })

      TestFactory.create_card(%{
        lands17_id: 9603,
        name: "Thoughtseize",
        types: "Sorcery",
        is_sorcery: true
      })

      :ok
    end

    test "single type filter returns only matching cards" do
      results = Cards.list_cards(%{types: MapSet.new([:instant])})
      names = Enum.map(results, & &1.name)
      assert "Lightning Bolt" in names
      refute "Llanowar Elves" in names
      refute "Forest" in names
    end

    test "multiple type filters use OR semantics" do
      results = Cards.list_cards(%{types: MapSet.new([:instant, :creature])})
      names = Enum.map(results, & &1.name)
      assert "Lightning Bolt" in names
      assert "Llanowar Elves" in names
      refute "Forest" in names
    end

    test "land type filter" do
      results = Cards.list_cards(%{types: MapSet.new([:land])})
      names = Enum.map(results, & &1.name)
      assert "Forest" in names
      refute "Lightning Bolt" in names
    end

    test "empty type filter returns all cards" do
      results = Cards.list_cards(%{types: MapSet.new()})
      assert length(results) >= 4
    end
  end

  describe "list_cards/1 — mana value filters" do
    setup do
      TestFactory.create_card(%{lands17_id: 9700, name: "Free Spell", mana_value: 0})
      TestFactory.create_card(%{lands17_id: 9701, name: "One Drop", mana_value: 1})
      TestFactory.create_card(%{lands17_id: 9702, name: "Three Drop", mana_value: 3})
      TestFactory.create_card(%{lands17_id: 9703, name: "Big Spell", mana_value: 10})
      :ok
    end

    test "exact mana value filter" do
      results = Cards.list_cards(%{mana_values: MapSet.new([3])})
      names = Enum.map(results, & &1.name)
      assert "Three Drop" in names
      refute "One Drop" in names
    end

    test "multiple mana values use OR semantics" do
      results = Cards.list_cards(%{mana_values: MapSet.new([0, 1])})
      names = Enum.map(results, & &1.name)
      assert "Free Spell" in names
      assert "One Drop" in names
      refute "Three Drop" in names
    end

    test ":seven_plus matches mana_value >= 7" do
      results = Cards.list_cards(%{mana_values: MapSet.new([:seven_plus])})
      names = Enum.map(results, & &1.name)
      assert "Big Spell" in names
      refute "Three Drop" in names
    end

    test ":seven_plus combined with exact values" do
      results = Cards.list_cards(%{mana_values: MapSet.new([1, :seven_plus])})
      names = Enum.map(results, & &1.name)
      assert "One Drop" in names
      assert "Big Spell" in names
      refute "Free Spell" in names
    end
  end

  describe "count_cards/1" do
    test "counts cards matching filters" do
      TestFactory.create_card(%{
        lands17_id: 9800,
        name: "Count Me",
        rarity: "rare",
        is_creature: true
      })

      TestFactory.create_card(%{
        lands17_id: 9801,
        name: "Skip Me",
        rarity: "common",
        is_creature: false
      })

      count = Cards.count_cards(%{rarity: "rare"})
      assert count >= 1
    end

    test "ignores :limit and :order_by keys" do
      assert is_integer(Cards.count_cards(%{limit: 1, order_by: :name}))
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
