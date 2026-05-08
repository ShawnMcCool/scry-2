defmodule Scry2.Cards.Synthesize.MergeFieldsTest do
  @moduledoc """
  Tests for `Scry2.Cards.Synthesize.MergeFields` — pure per-card field
  merge logic (relocated from `Scry2.Cards.SynthesizeTest`). Uses struct
  literals; no DB.
  """

  use ExUnit.Case, async: true

  alias Scry2.Cards.Synthesize.MergeFields
  alias Scry2.TestFactory

  describe "front_name/1" do
    test "strips the back face on double-faced cards" do
      assert MergeFields.front_name("Akoum Hellhound // Akoum Hellkite") == "Akoum Hellhound"
    end

    test "passes single-face names through" do
      assert MergeFields.front_name("Lightning Bolt") == "Lightning Bolt"
    end

    test "handles names with no spaces" do
      assert MergeFields.front_name("Mountain") == "Mountain"
    end
  end

  describe "derive_type_booleans/1 (Scryfall-style type_line)" do
    test "Creature is set for creature type lines" do
      flags = MergeFields.derive_type_booleans("Creature — Goblin")
      assert flags.is_creature == true
      assert flags.is_instant == false
      assert flags.is_land == false
    end

    test "Instant" do
      flags = MergeFields.derive_type_booleans("Instant")
      assert flags.is_instant == true
      assert flags.is_creature == false
    end

    test "Sorcery" do
      flags = MergeFields.derive_type_booleans("Sorcery")
      assert flags.is_sorcery == true
    end

    test "Enchantment" do
      flags = MergeFields.derive_type_booleans("Enchantment — Aura")
      assert flags.is_enchantment == true
    end

    test "Artifact" do
      flags = MergeFields.derive_type_booleans("Artifact — Vehicle")
      assert flags.is_artifact == true
    end

    test "Planeswalker" do
      flags = MergeFields.derive_type_booleans("Legendary Planeswalker — Jace")
      assert flags.is_planeswalker == true
    end

    test "Land" do
      flags = MergeFields.derive_type_booleans("Basic Land — Mountain")
      assert flags.is_land == true
    end

    test "Battle" do
      flags = MergeFields.derive_type_booleans("Battle — Siege")
      assert flags.is_battle == true
    end

    test "multi-typed cards (e.g. Artifact Creature) set both flags" do
      flags = MergeFields.derive_type_booleans("Artifact Creature — Construct")
      assert flags.is_artifact == true
      assert flags.is_creature == true
    end

    test "empty string yields all-false booleans" do
      flags = MergeFields.derive_type_booleans("")
      assert flags.is_creature == false
      assert flags.is_instant == false
      assert flags.is_land == false
    end
  end

  describe "decode_mtga_types/1 (MTGA enum)" do
    test "decodes MTGA's comma-separated integer enum to readable types" do
      assert MergeFields.decode_mtga_types("2") =~ "Creature"
      assert MergeFields.decode_mtga_types("4") =~ "Instant"
      assert MergeFields.decode_mtga_types("10") =~ "Sorcery"
      assert MergeFields.decode_mtga_types("5") =~ "Land"
      assert MergeFields.decode_mtga_types("1") =~ "Artifact"
      assert MergeFields.decode_mtga_types("3") =~ "Enchantment"
      assert MergeFields.decode_mtga_types("8") =~ "Planeswalker"
    end

    test "multi-type creature land decodes both names" do
      decoded = MergeFields.decode_mtga_types("2,5")
      assert decoded =~ "Creature"
      assert decoded =~ "Land"
    end

    test "empty/nil returns empty string" do
      assert MergeFields.decode_mtga_types(nil) == ""
      assert MergeFields.decode_mtga_types("") == ""
    end
  end

  describe "build/2 — both sources present" do
    test "Scryfall fields take precedence for enrichable data" do
      mtga =
        TestFactory.build_mtga_card(
          arena_id: 91_001,
          name: "MTGA Name",
          types: "2",
          mana_value: 1,
          collector_number: "42"
        )

      scryfall =
        TestFactory.build_scryfall_card(
          arena_id: 91_001,
          name: "Scryfall Name",
          type_line: "Creature — Goblin",
          color_identity: "R",
          cmc: 2.0,
          rarity: "common",
          set_code: "lci",
          collector_number: "42",
          booster: true
        )

      attrs = MergeFields.build(mtga, scryfall)

      assert attrs.arena_id == 91_001
      # Scryfall name preferred
      assert attrs.name == "Scryfall Name"
      # MTGA collector_number preferred
      assert attrs.collector_number == "42"
      assert attrs.types == "Creature — Goblin"
      assert attrs.is_creature == true
      # Scryfall color_identity preferred
      assert attrs.color_identity == "R"
      # Scryfall cmc rounded to integer mana_value
      assert attrs.mana_value == 2
      # Scryfall rarity preferred
      assert attrs.rarity == "common"
      assert attrs.is_booster == true
    end
  end

  describe "build/2 — MTGA-only" do
    test "uses MTGA values, decodes type enum, defaults missing fields" do
      mtga =
        TestFactory.build_mtga_card(
          arena_id: 92_001,
          name: "MTGA Only",
          types: "2",
          mana_value: 3,
          rarity: 4,
          expansion_code: "FDN",
          collector_number: "001"
        )

      attrs = MergeFields.build(mtga, nil)

      assert attrs.arena_id == 92_001
      assert attrs.name == "MTGA Only"
      assert attrs.collector_number == "001"
      assert attrs.types =~ "Creature"
      assert attrs.is_creature == true
      assert attrs.mana_value == 3
      # rarity 4 = rare per MTGA enum
      assert attrs.rarity == "rare"
      # color identity unknown without Scryfall — empty
      assert attrs.color_identity == ""
    end

    test "tokens never get is_booster=true (Pairing skips tokens, default-true must not flip them on)" do
      token =
        TestFactory.build_mtga_card(
          arena_id: 92_500,
          name: "Goblin Token",
          rarity: 0,
          is_token: true,
          expansion_code: "SOS",
          collector_number: "001"
        )

      assert MergeFields.build(token, nil).is_booster == false
    end

    test "decodes MTGA rarity enum (0=token, 1=basic, 2=common, 3=uncommon, 4=rare, 5=mythic)" do
      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 1, rarity: 0), nil).rarity ==
               "token"

      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 2, rarity: 1), nil).rarity ==
               "basic"

      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 3, rarity: 2), nil).rarity ==
               "common"

      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 4, rarity: 3), nil).rarity ==
               "uncommon"

      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 5, rarity: 4), nil).rarity ==
               "rare"

      assert MergeFields.build(TestFactory.build_mtga_card(arena_id: 6, rarity: 5), nil).rarity ==
               "mythic"
    end
  end

  describe "build/2 — Scryfall-only" do
    test "uses Scryfall values, derives types from type_line" do
      scryfall =
        TestFactory.build_scryfall_card(
          arena_id: 93_001,
          name: "Rotated Card",
          type_line: "Sorcery",
          color_identity: "U",
          cmc: 4.0,
          rarity: "rare",
          set_code: "thb",
          collector_number: "077",
          booster: false
        )

      attrs = MergeFields.build(nil, scryfall)

      assert attrs.arena_id == 93_001
      assert attrs.name == "Rotated Card"
      # collector_number falls through to Scryfall when MTGA is absent
      assert attrs.collector_number == "077"
      assert attrs.types == "Sorcery"
      assert attrs.is_sorcery == true
      assert attrs.color_identity == "U"
      assert attrs.mana_value == 4
      assert attrs.rarity == "rare"
      assert attrs.is_booster == false
    end

    test "splits DFC names using front_name when present" do
      scryfall =
        TestFactory.build_scryfall_card(
          arena_id: 93_002,
          name: "Akoum Hellhound // Akoum Hellkite",
          type_line: "Creature — Hound // Creature — Dragon"
        )

      attrs = MergeFields.build(nil, scryfall)
      assert attrs.name == "Akoum Hellhound"
    end
  end

  describe "build/2 — both nil" do
    test "returns nil" do
      assert MergeFields.build(nil, nil) == nil
    end
  end

  describe "prefer_booster/2" do
    test "prefers the booster=true row" do
      a = TestFactory.build_scryfall_card(scryfall_id: "a", booster: false)
      b = TestFactory.build_scryfall_card(scryfall_id: "b", booster: true)

      assert MergeFields.prefer_booster(a, b).scryfall_id == "b"
      assert MergeFields.prefer_booster(b, a).scryfall_id == "b"
    end

    test "keeps the first when neither is booster=true" do
      a = TestFactory.build_scryfall_card(scryfall_id: "a", booster: false)
      b = TestFactory.build_scryfall_card(scryfall_id: "b", booster: false)

      assert MergeFields.prefer_booster(a, b).scryfall_id == "a"
    end
  end
end
