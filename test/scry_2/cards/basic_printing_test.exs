defmodule Scry2.Cards.BasicPrintingTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.BasicPrinting
  alias Scry2.TestFactory

  describe "most_basic/1 — treatment axes" do
    test "returns nil for no printings" do
      assert BasicPrinting.most_basic([]) == nil
    end

    test "a plain printing beats a promo printing" do
      promo = TestFactory.build_scryfall_card(scryfall_id: "promo", promo: true)
      plain = TestFactory.build_scryfall_card(scryfall_id: "plain")

      assert BasicPrinting.most_basic([promo, plain]).scryfall_id == "plain"
    end

    test "a plain printing beats a full-art printing" do
      full_art = TestFactory.build_scryfall_card(scryfall_id: "fa", full_art: true)
      plain = TestFactory.build_scryfall_card(scryfall_id: "plain")

      assert BasicPrinting.most_basic([full_art, plain]).scryfall_id == "plain"
    end

    test "a plain printing beats a variation printing" do
      variation = TestFactory.build_scryfall_card(scryfall_id: "var", variation: true)
      plain = TestFactory.build_scryfall_card(scryfall_id: "plain")

      assert BasicPrinting.most_basic([variation, plain]).scryfall_id == "plain"
    end

    test "a plain frame beats showcase / extended-art frame effects" do
      showcase =
        TestFactory.build_scryfall_card(scryfall_id: "show", frame_effects: "showcase")

      plain = TestFactory.build_scryfall_card(scryfall_id: "plain", frame_effects: "")

      assert BasicPrinting.most_basic([showcase, plain]).scryfall_id == "plain"
    end

    test "a black border beats a borderless printing" do
      borderless =
        TestFactory.build_scryfall_card(scryfall_id: "bl", border_color: "borderless")

      plain = TestFactory.build_scryfall_card(scryfall_id: "plain", border_color: "black")

      assert BasicPrinting.most_basic([borderless, plain]).scryfall_id == "plain"
    end

    test "an in-booster printing beats an out-of-booster one" do
      special = TestFactory.build_scryfall_card(scryfall_id: "special", booster: false)
      pack = TestFactory.build_scryfall_card(scryfall_id: "pack", booster: true)

      assert BasicPrinting.most_basic([special, pack]).scryfall_id == "pack"
    end

    test "unknown treatment metadata is not evidence of specialness" do
      # Rows imported before the treatment columns existed carry nils —
      # they rank as basic, not special.
      unknown =
        TestFactory.build_scryfall_card(
          scryfall_id: "old",
          promo: nil,
          full_art: nil,
          variation: nil,
          frame_effects: nil,
          border_color: nil,
          booster: nil
        )

      promo = TestFactory.build_scryfall_card(scryfall_id: "promo", promo: true)

      assert BasicPrinting.most_basic([promo, unknown]).scryfall_id == "old"
    end

    test "one special axis loses even when the other printing is out of booster" do
      # Axis order: any art treatment outranks booster membership.
      showcase_in_booster =
        TestFactory.build_scryfall_card(
          scryfall_id: "show",
          frame_effects: "showcase",
          booster: true
        )

      plain_out_of_booster =
        TestFactory.build_scryfall_card(scryfall_id: "plain", booster: false)

      assert BasicPrinting.most_basic([showcase_in_booster, plain_out_of_booster]).scryfall_id ==
               "plain"
    end
  end

  describe "most_basic/1 — flavor-name overlays" do
    test "the canonical row beats a flavor-name row (literal quotes in name)" do
      # Scryfall's bulk data publishes flavor-name treatments (Universes
      # Beyond, parody overlays, etc.) as separate rows at the same
      # (set, number) with the flavor name wrapped in literal double
      # quotes. They are cosmetic variants, never the display printing.
      canonical =
        TestFactory.build_scryfall_card(
          scryfall_id: "real",
          name: "Wildgrowth Archaic",
          booster: false
        )

      flavor =
        TestFactory.build_scryfall_card(
          scryfall_id: "flavor",
          name: ~s("The Very Hungry Archaic"),
          booster: false
        )

      assert BasicPrinting.most_basic([canonical, flavor]).scryfall_id == "real"
      assert BasicPrinting.most_basic([flavor, canonical]).scryfall_id == "real"
    end

    test "canonical+booster beats flavor+booster" do
      canonical =
        TestFactory.build_scryfall_card(
          scryfall_id: "real",
          name: "Wildgrowth Archaic",
          booster: true
        )

      flavor =
        TestFactory.build_scryfall_card(
          scryfall_id: "flavor",
          name: ~s("The Very Hungry Archaic"),
          booster: true
        )

      assert BasicPrinting.most_basic([canonical, flavor]).scryfall_id == "real"
      assert BasicPrinting.most_basic([flavor, canonical]).scryfall_id == "real"
    end

    test "a flavor-name row outranks nothing — even a promo beats it" do
      flavor =
        TestFactory.build_scryfall_card(
          scryfall_id: "flavor",
          name: ~s("Parody Name")
        )

      promo = TestFactory.build_scryfall_card(scryfall_id: "promo", promo: true)

      assert BasicPrinting.most_basic([flavor, promo]).scryfall_id == "promo"
    end
  end

  describe "most_basic/1 — tiebreaks" do
    test "lower numeric collector number wins among equally basic printings" do
      high = TestFactory.build_scryfall_card(scryfall_id: "high", collector_number: "412")
      low = TestFactory.build_scryfall_card(scryfall_id: "low", collector_number: "58")

      assert BasicPrinting.most_basic([high, low]).scryfall_id == "low"
    end

    test "numeric collector numbers beat non-numeric ones" do
      alchemy = TestFactory.build_scryfall_card(scryfall_id: "alchemy", collector_number: "A-58")
      plain = TestFactory.build_scryfall_card(scryfall_id: "plain", collector_number: "412")

      assert BasicPrinting.most_basic([alchemy, plain]).scryfall_id == "plain"
    end

    test "earlier release wins when collector numbers tie" do
      newer =
        TestFactory.build_scryfall_card(
          scryfall_id: "newer",
          collector_number: "58",
          released_at: ~D[2026-03-01]
        )

      older =
        TestFactory.build_scryfall_card(
          scryfall_id: "older",
          collector_number: "58",
          released_at: ~D[2024-09-15]
        )

      assert BasicPrinting.most_basic([newer, older]).scryfall_id == "older"
    end

    test "keeps the first when nothing distinguishes the printings" do
      a = TestFactory.build_scryfall_card(scryfall_id: "a")
      b = TestFactory.build_scryfall_card(scryfall_id: "b")

      assert BasicPrinting.most_basic([a, b]).scryfall_id == "a"
    end
  end
end
