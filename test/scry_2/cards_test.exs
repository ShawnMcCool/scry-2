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

  describe "list_sets/0" do
    test "returns sets newest-first by released_at" do
      _old = Cards.upsert_set!(%{code: "OLD", name: "Old", released_at: ~D[2024-01-01]})
      _mid = Cards.upsert_set!(%{code: "MID", name: "Mid", released_at: ~D[2025-01-01]})
      _new = Cards.upsert_set!(%{code: "NEW", name: "New", released_at: ~D[2026-01-01]})

      codes = Cards.list_sets() |> Enum.map(& &1.code)

      assert codes == ["NEW", "MID", "OLD"]
    end

    test "places sets without released_at last" do
      _dated = Cards.upsert_set!(%{code: "DTD", name: "Dated", released_at: ~D[2026-01-01]})
      _undated = Cards.upsert_set!(%{code: "UND", name: "Undated"})

      codes = Cards.list_sets() |> Enum.map(& &1.code)

      assert codes == ["DTD", "UND"]
    end

    test "returns an empty list when no sets exist" do
      assert Cards.list_sets() == []
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

  # Display-art lookups read the columns Synthesize stamps onto
  # cards_cards (the name's most basic printing — Scry2.Cards.BasicPrinting).
  # The old multi-path Scryfall-join scenarios (flavor-name demotion,
  # canonical-printing preference) moved to BasicPrintingTest and the
  # SynthesizeTest stamping tests.
  describe "get_art_url_for_arena_id/1" do
    test "returns the stamped art_crop url" do
      Cards.synthesize_card!(%{
        arena_id: 700_010,
        name: "Art Test",
        art_crop_url: "http://x/art.jpg"
      })

      assert Cards.get_art_url_for_arena_id(700_010) == "http://x/art.jpg"
    end
  end

  describe "get_image_url_for_arena_id/1" do
    test "returns the stamped image url" do
      Cards.synthesize_card!(%{
        arena_id: 700_001,
        name: "Image Test",
        image_url: "https://example.com/basic.jpg"
      })

      assert Cards.get_image_url_for_arena_id(700_001) == "https://example.com/basic.jpg"
    end

    test "returns nil for unstamped or unknown rows so ImageCache can fall back to the live API" do
      Cards.synthesize_card!(%{arena_id: 700_002, name: "Unstamped"})

      assert Cards.get_image_url_for_arena_id(700_002) == nil
      assert Cards.get_image_url_for_arena_id(799_999) == nil
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

  describe "list_booster_cards_by_set/1" do
    test "returns booster-legal cards for the set" do
      set = TestFactory.create_set(%{code: "BLB", name: "Bloomburrow"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_001,
          set_id: set.id,
          rarity: "common",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_002,
          set_id: set.id,
          rarity: "rare",
          is_booster: true
        })

      result = Cards.list_booster_cards_by_set(set.id)

      arena_ids = result |> Enum.map(& &1.arena_id) |> Enum.sort()
      assert arena_ids == [95_001, 95_002]
      assert Enum.all?(result, &match?(%Cards.Card{}, &1))
    end

    test "excludes non-booster cards (Alchemy duplicates, basics, tokens)" do
      set = TestFactory.create_set(%{code: "ALC2", name: "Alchemy 2"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_101,
          set_id: set.id,
          rarity: "rare",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_102,
          set_id: set.id,
          rarity: "rare",
          is_booster: false
        })

      arena_ids =
        set.id |> Cards.list_booster_cards_by_set() |> Enum.map(& &1.arena_id)

      assert arena_ids == [95_101]
    end

    test "excludes basics and tokens regardless of booster signal" do
      set = TestFactory.create_set(%{code: "BSC", name: "Basics"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_201,
          set_id: set.id,
          rarity: "common",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_202,
          set_id: set.id,
          rarity: "basic",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_203,
          set_id: set.id,
          rarity: "token",
          is_booster: true
        })

      arena_ids =
        set.id |> Cards.list_booster_cards_by_set() |> Enum.map(& &1.arena_id)

      assert arena_ids == [95_201]
    end

    test "excludes cards from other sets" do
      target = TestFactory.create_set(%{code: "TGT", name: "Target"})
      other = TestFactory.create_set(%{code: "OTH", name: "Other"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_301,
          set_id: target.id,
          rarity: "rare",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_302,
          set_id: other.id,
          rarity: "rare",
          is_booster: true
        })

      arena_ids =
        target.id |> Cards.list_booster_cards_by_set() |> Enum.map(& &1.arena_id)

      assert arena_ids == [95_301]
    end

    test "lag fallback: includes non-booster cards when set has zero booster signal" do
      # Mirrors SetRoster.compute/0's lag fallback so totals match the tile counts.
      lagged = TestFactory.create_set(%{code: "SOS2", name: "Secrets Lag"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_401,
          set_id: lagged.id,
          rarity: "common",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 95_402,
          set_id: lagged.id,
          rarity: "mythic",
          is_booster: false
        })

      arena_ids =
        lagged.id |> Cards.list_booster_cards_by_set() |> Enum.map(& &1.arena_id) |> Enum.sort()

      assert arena_ids == [95_401, 95_402]
    end

    test "returns empty list for unknown set_id" do
      assert Cards.list_booster_cards_by_set(-1) == []
    end
  end

  describe "printings_by_name/1" do
    test "groups every arena_id sharing a (case-insensitive) name" do
      first = TestFactory.create_card(name: "Roaring Furnace")
      second = TestFactory.create_card(name: "Roaring Furnace")
      _other = TestFactory.create_card(name: "Lightning Bolt")

      result = Cards.printings_by_name(["roaring furnace", "Absent Card"])

      assert Enum.sort(result["roaring furnace"]) ==
               Enum.sort([first.arena_id, second.arena_id])

      refute Map.has_key?(result, "absent card")
    end
  end

  describe "resolve_references/1 DFC fallback" do
    test "resolves a double-faced name (Front // Back) to the front-face card" do
      front = TestFactory.create_card(name: "Roaring Furnace")

      refs = [
        %{
          name: "Roaring Furnace // Steaming Sauna",
          set_code: nil,
          collector_number: nil,
          count: 2
        }
      ]

      assert %{resolved: [%{arena_id: arena_id, count: 2}], unresolved: []} =
               Cards.resolve_references(refs)

      assert arena_id == front.arena_id
    end

    test "a true split card stored with // matches its full name first" do
      split = TestFactory.create_card(name: "Crude Abattoir // Unsavory Kitchen")

      refs = [
        %{
          name: "Crude Abattoir // Unsavory Kitchen",
          set_code: nil,
          collector_number: nil,
          count: 1
        }
      ]

      assert %{resolved: [%{arena_id: arena_id}]} = Cards.resolve_references(refs)
      assert arena_id == split.arena_id
    end
  end

  describe "representative_arena_ids/1" do
    test "maps every printing of a card name onto one stable representative" do
      island_a = TestFactory.create_card(arena_id: 105_175, name: "Island")
      island_b = TestFactory.create_card(arena_id: 102_727, name: "Island")

      reps = Cards.representative_arena_ids([island_a.arena_id, island_b.arena_id])

      # Both printings collapse to the same representative...
      assert reps[105_175] == reps[102_727]
      # ...and that representative is stable (the lowest printing arena_id).
      assert reps[105_175] == 102_727
    end

    test "distinct card names keep distinct representatives" do
      island = TestFactory.create_card(arena_id: 105_175, name: "Island")
      mountain = TestFactory.create_card(arena_id: 95_072, name: "Mountain")

      reps = Cards.representative_arena_ids([island.arena_id, mountain.arena_id])

      refute reps[105_175] == reps[95_072]
    end

    test "arena_ids with no card row fall back to themselves" do
      reps = Cards.representative_arena_ids([999_999])
      assert reps[999_999] == 999_999
    end

    test "returns an empty map for an empty input" do
      assert Cards.representative_arena_ids([]) == %{}
    end
  end
end
