defmodule Scry2.Cards.SynthesizeTest do
  @moduledoc """
  Tests for `Scry2.Cards.Synthesize`.

  Pure-function tests use struct literals and run with `async: true`. Integration
  tests use `DataCase` and exercise the full pipeline end-to-end.
  """

  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.Synthesize

  describe "front_name/1 (pure)" do
    test "strips the back face on double-faced cards" do
      assert Synthesize.front_name("Akoum Hellhound // Akoum Hellkite") == "Akoum Hellhound"
    end

    test "passes single-face names through" do
      assert Synthesize.front_name("Lightning Bolt") == "Lightning Bolt"
    end

    test "handles names with no spaces" do
      assert Synthesize.front_name("Mountain") == "Mountain"
    end
  end

  describe "derive_type_booleans/1 (pure, Scryfall-style type_line)" do
    test "Creature is set for creature type lines" do
      flags = Synthesize.derive_type_booleans("Creature — Goblin")
      assert flags.is_creature == true
      assert flags.is_instant == false
      assert flags.is_land == false
    end

    test "Instant" do
      flags = Synthesize.derive_type_booleans("Instant")
      assert flags.is_instant == true
      assert flags.is_creature == false
    end

    test "Sorcery" do
      flags = Synthesize.derive_type_booleans("Sorcery")
      assert flags.is_sorcery == true
    end

    test "Enchantment" do
      flags = Synthesize.derive_type_booleans("Enchantment — Aura")
      assert flags.is_enchantment == true
    end

    test "Artifact" do
      flags = Synthesize.derive_type_booleans("Artifact — Vehicle")
      assert flags.is_artifact == true
    end

    test "Planeswalker" do
      flags = Synthesize.derive_type_booleans("Legendary Planeswalker — Jace")
      assert flags.is_planeswalker == true
    end

    test "Land" do
      flags = Synthesize.derive_type_booleans("Basic Land — Mountain")
      assert flags.is_land == true
    end

    test "Battle" do
      flags = Synthesize.derive_type_booleans("Battle — Siege")
      assert flags.is_battle == true
    end

    test "multi-typed cards (e.g. Artifact Creature) set both flags" do
      flags = Synthesize.derive_type_booleans("Artifact Creature — Construct")
      assert flags.is_artifact == true
      assert flags.is_creature == true
    end

    test "empty string yields all-false booleans" do
      flags = Synthesize.derive_type_booleans("")
      assert flags.is_creature == false
      assert flags.is_instant == false
      assert flags.is_land == false
    end
  end

  describe "decode_mtga_types/1 (pure, MTGA enum)" do
    test "decodes MTGA's comma-separated integer enum to readable types" do
      assert Synthesize.decode_mtga_types("2") =~ "Creature"
      assert Synthesize.decode_mtga_types("4") =~ "Instant"
      assert Synthesize.decode_mtga_types("10") =~ "Sorcery"
      assert Synthesize.decode_mtga_types("5") =~ "Land"
      assert Synthesize.decode_mtga_types("1") =~ "Artifact"
      assert Synthesize.decode_mtga_types("3") =~ "Enchantment"
      assert Synthesize.decode_mtga_types("8") =~ "Planeswalker"
    end

    test "multi-type creature land decodes both names" do
      decoded = Synthesize.decode_mtga_types("2,5")
      assert decoded =~ "Creature"
      assert decoded =~ "Land"
    end

    test "empty/nil returns empty string" do
      assert Synthesize.decode_mtga_types(nil) == ""
      assert Synthesize.decode_mtga_types("") == ""
    end
  end

  describe "build_card_attrs/2 — both sources present" do
    test "Scryfall fields take precedence for enrichable data" do
      mtga = build_mtga_struct(arena_id: 91_001, name: "MTGA Name", types: "2", mana_value: 1)

      scryfall =
        build_scryfall_struct(
          arena_id: 91_001,
          name: "Scryfall Name",
          type_line: "Creature — Goblin",
          color_identity: "R",
          cmc: 2.0,
          rarity: "common",
          set_code: "lci",
          booster: true
        )

      attrs = Synthesize.build_card_attrs(mtga, scryfall)

      assert attrs.arena_id == 91_001
      # Scryfall name preferred
      assert attrs.name == "Scryfall Name"
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

  describe "build_card_attrs/2 — MTGA-only" do
    test "uses MTGA values, decodes type enum, defaults missing fields" do
      mtga =
        build_mtga_struct(
          arena_id: 92_001,
          name: "MTGA Only",
          types: "2",
          mana_value: 3,
          rarity: 4,
          expansion_code: "FDN"
        )

      attrs = Synthesize.build_card_attrs(mtga, nil)

      assert attrs.arena_id == 92_001
      assert attrs.name == "MTGA Only"
      assert attrs.types =~ "Creature"
      assert attrs.is_creature == true
      assert attrs.mana_value == 3
      # rarity 4 = rare per MTGA enum
      assert attrs.rarity == "rare"
      # color identity unknown without Scryfall — empty
      assert attrs.color_identity == ""
    end

    test "decodes MTGA rarity enum (0=token, 1=basic, 2=common, 3=uncommon, 4=rare, 5=mythic)" do
      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 1, rarity: 0), nil).rarity ==
               "token"

      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 2, rarity: 1), nil).rarity ==
               "basic"

      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 3, rarity: 2), nil).rarity ==
               "common"

      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 4, rarity: 3), nil).rarity ==
               "uncommon"

      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 5, rarity: 4), nil).rarity ==
               "rare"

      assert Synthesize.build_card_attrs(build_mtga_struct(arena_id: 6, rarity: 5), nil).rarity ==
               "mythic"
    end
  end

  describe "build_card_attrs/2 — Scryfall-only" do
    test "uses Scryfall values, derives types from type_line" do
      scryfall =
        build_scryfall_struct(
          arena_id: 93_001,
          name: "Rotated Card",
          type_line: "Sorcery",
          color_identity: "U",
          cmc: 4.0,
          rarity: "rare",
          set_code: "thb",
          booster: false
        )

      attrs = Synthesize.build_card_attrs(nil, scryfall)

      assert attrs.arena_id == 93_001
      assert attrs.name == "Rotated Card"
      assert attrs.types == "Sorcery"
      assert attrs.is_sorcery == true
      assert attrs.color_identity == "U"
      assert attrs.mana_value == 4
      assert attrs.rarity == "rare"
      assert attrs.is_booster == false
    end

    test "splits DFC names using front_name when present" do
      scryfall =
        build_scryfall_struct(
          arena_id: 93_002,
          name: "Akoum Hellhound // Akoum Hellkite",
          type_line: "Creature — Hound // Creature — Dragon"
        )

      attrs = Synthesize.build_card_attrs(nil, scryfall)
      assert attrs.name == "Akoum Hellhound"
    end
  end

  describe "build_card_attrs/2 — both nil" do
    test "returns nil" do
      assert Synthesize.build_card_attrs(nil, nil) == nil
    end
  end

  describe "run/1 (integration)" do
    test "synthesizes a row for an MTGA-only arena_id" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_001,
        name: "MTGA Solo",
        expansion_code: "FDN",
        types: "2",
        rarity: 4,
        mana_value: 3
      })

      assert {:ok, %{synthesized: count, mtga_only: 1}} = Synthesize.run([])
      assert count >= 1

      card = Cards.get_by_arena_id(80_001)
      assert card.name == "MTGA Solo"
      assert card.is_creature == true
    end

    test "synthesizes a row for a Scryfall-only arena_id" do
      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-sf-only",
        arena_id: 80_002,
        name: "Scryfall Solo",
        type_line: "Instant",
        set_code: "thb",
        rarity: "rare"
      })

      assert {:ok, %{synthesized: count, scryfall_only: scryfall_only}} = Synthesize.run([])
      assert count >= 1
      assert scryfall_only >= 1

      card = Cards.get_by_arena_id(80_002)
      assert card.name == "Scryfall Solo"
      assert card.is_instant == true
      assert card.rarity == "rare"
    end

    test "merges both sources into a single row when arena_id matches" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_003,
        name: "MTGA Form",
        expansion_code: "FDN",
        types: "2",
        rarity: 4,
        mana_value: 1
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-merge",
        arena_id: 80_003,
        name: "Scryfall Form",
        type_line: "Creature — Goblin",
        color_identity: "R",
        cmc: 2.0,
        rarity: "common",
        set_code: "fdn"
      })

      assert {:ok, _stats} = Synthesize.run([])

      card = Cards.get_by_arena_id(80_003)
      # Scryfall name preferred (richer source)
      assert card.name == "Scryfall Form"
      assert card.color_identity == "R"
      assert card.is_creature == true
    end

    test "is idempotent (re-running yields same state)" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_004,
        name: "Idempotent",
        expansion_code: "FDN",
        types: "2",
        rarity: 4
      })

      assert {:ok, _} = Synthesize.run([])
      first_count = Cards.count()

      assert {:ok, _} = Synthesize.run([])
      second_count = Cards.count()

      assert first_count == second_count
    end

    test "creates set rows from Scryfall set codes" do
      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-set",
        arena_id: 80_005,
        name: "Set Test",
        type_line: "Instant",
        set_code: "fdn",
        rarity: "common"
      })

      assert {:ok, _} = Synthesize.run([])

      assert Cards.get_set_by_code("FDN") != nil
    end

    test "broadcasts cards_updates with the synthesized count" do
      Scry2.Topics.subscribe(Scry2.Topics.cards_updates())

      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_006,
        name: "Broadcast",
        expansion_code: "FDN",
        types: "2",
        rarity: 2
      })

      {:ok, _} = Synthesize.run([])

      assert_receive {:cards_refreshed, _count}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp build_mtga_struct(attrs) do
    Scry2.TestFactory.build_mtga_card(attrs)
  end

  defp build_scryfall_struct(attrs) do
    Scry2.TestFactory.build_scryfall_card(attrs)
  end
end
