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

  describe "synthesize_card!/1" do
    test "creates a new card keyed on arena_id" do
      card =
        Cards.synthesize_card!(%{
          arena_id: 91_001,
          name: "Test Card",
          rarity: "rare"
        })

      assert card.arena_id == 91_001
      assert card.name == "Test Card"
    end

    test "updates an existing card by arena_id (idempotent)" do
      first = Cards.synthesize_card!(%{arena_id: 91_002, name: "Old Name"})
      second = Cards.synthesize_card!(%{arena_id: 91_002, name: "New Name"})

      assert first.id == second.id
      assert second.name == "New Name"
    end
  end

  describe "get_by_arena_id/1" do
    test "returns nil for unknown arena_ids" do
      assert Cards.get_by_arena_id(99_999_999) == nil
    end

    test "returns the card when found" do
      card = TestFactory.create_card(%{arena_id: 91_100})
      assert Cards.get_by_arena_id(91_100).id == card.id
    end
  end

  describe "upsert_scryfall_card!/1" do
    test "creates a new scryfall card" do
      card =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-123",
          name: "Lightning Bolt",
          set_code: "lci",
          rarity: "common"
        })

      assert card.scryfall_id == "abc-123"
      assert card.name == "Lightning Bolt"
    end

    test "updates an existing card by scryfall_id (idempotent)" do
      first =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-456",
          name: "Old Name",
          set_code: "lci"
        })

      second =
        Cards.upsert_scryfall_card!(%{
          scryfall_id: "abc-456",
          name: "New Name",
          set_code: "lci"
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

  describe "refresh timestamps" do
    test "import_timestamps/0 returns nil for all sources when never stamped" do
      Scry2.Settings.delete("cards_synthesized_last_refresh_at")
      Scry2.Settings.delete("cards_scryfall_last_refresh_at")
      Scry2.Settings.delete("cards_mtga_client_last_refresh_at")

      result = Cards.import_timestamps()
      assert is_nil(result.synthesized_updated_at)
      assert is_nil(result.scryfall_updated_at)
      assert is_nil(result.mtga_client_updated_at)
    end

    test "record_synthesis_refresh!/1 writes a retrievable DateTime" do
      now = ~U[2026-04-24 12:00:00Z]
      :ok = Cards.record_synthesis_refresh!(now)

      assert %{synthesized_updated_at: ^now} = Cards.import_timestamps()
    end

    test "record_scryfall_refresh!/1 writes a retrievable DateTime" do
      now = ~U[2026-04-24 12:00:00Z]
      :ok = Cards.record_scryfall_refresh!(now)

      assert %{scryfall_updated_at: ^now} = Cards.import_timestamps()
    end

    test "record_mtga_client_refresh!/1 writes a retrievable DateTime" do
      now = ~U[2026-04-24 12:00:00Z]
      :ok = Cards.record_mtga_client_refresh!(now)

      assert %{mtga_client_updated_at: ^now} = Cards.import_timestamps()
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
      TestFactory.create_card(%{arena_id: 92_001, name: "Aardvark", rarity: "common"})
      TestFactory.create_card(%{arena_id: 92_002, name: "Zebra", rarity: "mythic"})
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
      TestFactory.create_card(%{arena_id: 93_001, name: "Red Card", color_identity: "R"})
      TestFactory.create_card(%{arena_id: 93_002, name: "Blue Card", color_identity: "U"})
      TestFactory.create_card(%{arena_id: 93_003, name: "Izzet Card", color_identity: "UR"})
      TestFactory.create_card(%{arena_id: 93_004, name: "Colorless Card", color_identity: ""})
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
        arena_id: 94_001,
        name: "Lightning Bolt",
        types: "Instant",
        is_instant: true,
        is_creature: false
      })

      TestFactory.create_card(%{
        arena_id: 94_002,
        name: "Llanowar Elves",
        types: "Creature Elf Druid",
        is_creature: true
      })

      TestFactory.create_card(%{
        arena_id: 94_003,
        name: "Forest",
        types: "Basic Land Forest",
        is_land: true,
        is_creature: false
      })

      TestFactory.create_card(%{
        arena_id: 94_004,
        name: "Thoughtseize",
        types: "Sorcery",
        is_sorcery: true,
        is_creature: false
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
      TestFactory.create_card(%{arena_id: 95_001, name: "Free Spell", mana_value: 0})
      TestFactory.create_card(%{arena_id: 95_002, name: "One Drop", mana_value: 1})
      TestFactory.create_card(%{arena_id: 95_003, name: "Three Drop", mana_value: 3})
      TestFactory.create_card(%{arena_id: 95_004, name: "Big Spell", mana_value: 10})
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
        arena_id: 96_001,
        name: "Count Me",
        rarity: "rare",
        is_creature: true
      })

      TestFactory.create_card(%{
        arena_id: 96_002,
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
    test "returns synthesised cards indexed by arena_id when found" do
      TestFactory.create_card(%{
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

    test "synthesised card is preferred over MtgaCard when both exist for the same arena_id" do
      TestFactory.create_card(%{
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
