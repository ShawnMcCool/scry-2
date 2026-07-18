defmodule Scry2.Cards.SynthesizeTest do
  @moduledoc """
  Integration tests for `Scry2.Cards.Synthesize.run/1` (the orchestrator).
  Pure-helper tests live in:

    * `Scry2.Cards.Synthesize.MergeFieldsTest`
    * `Scry2.Cards.Synthesize.PairingTest`
    * `Scry2.Cards.Synthesize.SetMetadataTest`
  """

  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.Synthesize

  describe "run/1" do
    test "synthesises a row for an MTGA-only arena_id" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_001,
        name: "MTGA Solo",
        expansion_code: "FDN",
        collector_number: "001",
        types: "2",
        rarity: 4,
        mana_value: 3
      })

      assert {:ok, %{synthesized: count, mtga: mtga_count}} = Synthesize.run([])
      assert count >= 1
      assert mtga_count >= 1

      card = Cards.get_by_arena_id(80_001)
      assert card.name == "MTGA Solo"
      assert card.is_creature == true
      # MTGA-only collector_number flows through to cards_cards
      assert card.collector_number == "001"
    end

    test "stamps every printing's display art from the name's most basic printing" do
      # Two Arena printings of one name: the plain original and a
      # borderless reprint. Both cards_cards rows must carry the plain
      # printing's art — Scry2 renders cards, not printings.
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_101,
        name: "Spirebluff Canal",
        expansion_code: "KLR",
        collector_number: "286"
      })

      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_102,
        name: "Spirebluff Canal",
        expansion_code: "OM1",
        collector_number: "377"
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-basic",
        arena_id: 80_101,
        name: "Spirebluff Canal",
        set_code: "klr",
        collector_number: "286",
        border_color: "black",
        image_uris: %{
          "normal" => "https://img/plain.jpg",
          "art_crop" => "https://img/plain-art.jpg"
        }
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-borderless",
        arena_id: 80_102,
        name: "Spirebluff Canal",
        set_code: "om1",
        collector_number: "377",
        border_color: "borderless",
        frame_effects: "showcase",
        image_uris: %{
          "normal" => "https://img/showcase.jpg",
          "art_crop" => "https://img/showcase-art.jpg"
        }
      })

      assert {:ok, _} = Synthesize.run([])

      plain = Cards.get_by_arena_id(80_101)
      showcase = Cards.get_by_arena_id(80_102)

      assert plain.image_url == "https://img/plain.jpg"
      assert plain.art_crop_url == "https://img/plain-art.jpg"
      assert showcase.image_url == "https://img/plain.jpg"
      assert showcase.art_crop_url == "https://img/plain-art.jpg"
    end

    test "excludes art-series printings from the display-art candidate pool" do
      # An "art series" printing (a hand-drawn art card, no arena_id) shares
      # the card's name and has a lower collector number, so it would win the
      # most-basic tiebreak — but it is not real card art and must never be
      # chosen. Regression for the Wan Shi Tong sketch-art bug.
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_301,
        name: "Wan Shi Tong, Librarian",
        expansion_code: "TLA",
        collector_number: "78"
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-normal-78",
        arena_id: 80_301,
        name: "Wan Shi Tong, Librarian",
        set_code: "tla",
        collector_number: "78",
        border_color: "black",
        layout: "normal",
        image_uris: %{
          "normal" => "https://img/wan-normal.jpg",
          "art_crop" => "https://img/wan-normal-art.jpg"
        }
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-artseries-33",
        name: "Wan Shi Tong, Librarian",
        set_code: "atla",
        collector_number: "33",
        border_color: "black",
        layout: "art_series",
        image_uris: %{
          "normal" => "https://img/wan-sketch.jpg",
          "art_crop" => "https://img/wan-sketch-art.jpg"
        }
      })

      assert {:ok, _} = Synthesize.run([])

      card = Cards.get_by_arena_id(80_301)
      assert card.image_url == "https://img/wan-normal.jpg"
      assert card.art_crop_url == "https://img/wan-normal-art.jpg"
    end

    test "display art falls back to a printing that actually has an image" do
      # The most basic printing lacks image_uris (Scryfall gap) — the
      # stamp comes from the most basic printing that has one.
      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-no-image",
        arena_id: 80_103,
        name: "Gapped Card",
        set_code: "one",
        collector_number: "10",
        image_uris: nil
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-promo-image",
        arena_id: 80_104,
        name: "Gapped Card",
        set_code: "pone",
        collector_number: "10p",
        promo: true,
        image_uris: %{"normal" => "https://img/promo.jpg"}
      })

      assert {:ok, _} = Synthesize.run([])

      assert Cards.get_by_arena_id(80_103).image_url == "https://img/promo.jpg"
      assert Cards.get_by_arena_id(80_104).image_url == "https://img/promo.jpg"
    end

    test "synthesises a row via the rotated pass for a Scryfall-only arena_id" do
      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-sf-only",
        arena_id: 80_002,
        name: "Scryfall Solo",
        type_line: "Instant",
        set_code: "thb",
        collector_number: "077",
        rarity: "rare"
      })

      assert {:ok, %{synthesized: count, rotated: rotated}} = Synthesize.run([])
      assert count >= 1
      assert rotated >= 1

      card = Cards.get_by_arena_id(80_002)
      assert card.name == "Scryfall Solo"
      assert card.is_instant == true
      assert card.rarity == "rare"
      assert card.collector_number == "077"
    end

    test "merges both sources via (set, number) join when arena_id matches" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_003,
        name: "MTGA Form",
        expansion_code: "FDN",
        collector_number: "100",
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
        set_code: "fdn",
        collector_number: "100"
      })

      assert {:ok, _stats} = Synthesize.run([])

      card = Cards.get_by_arena_id(80_003)
      # Scryfall name preferred (richer source)
      assert card.name == "Scryfall Form"
      assert card.color_identity == "R"
      assert card.is_creature == true
      assert card.collector_number == "100"
    end

    test "regression: enriches MTGA cards from Scryfall via (set, number) when Scryfall has no arena_id" do
      # The SOS / TMT / TLA scenario. MTGA has the card with an arena_id;
      # Scryfall has the same printing tagged with proper metadata but
      # arena_id is still nil (Scryfall hasn't backfilled). Synthesis
      # must still join them via (set, number) and produce an enriched
      # cards_cards row.
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 91_500,
        name: "Mtga Source Name",
        expansion_code: "SOS",
        collector_number: "042",
        types: "2",
        rarity: 4,
        mana_value: 2
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-sos-042",
        arena_id: nil,
        name: "Scryfall Source Name",
        type_line: "Creature — Faerie Wizard",
        color_identity: "U",
        cmc: 3.0,
        rarity: "rare",
        set_code: "sos",
        collector_number: "042",
        set_name: "Secrets of Strixhaven",
        released_at: ~D[2026-04-24],
        booster: true
      })

      assert {:ok, _} = Synthesize.run([])

      card = Cards.get_by_arena_id(91_500)
      # Scryfall enrichment flowed through despite arena_id miss.
      assert card.name == "Scryfall Source Name"
      assert card.types == "Creature — Faerie Wizard"
      assert card.color_identity == "U"
      assert card.rarity == "rare"
      assert card.mana_value == 3
      assert card.collector_number == "042"

      # Set metadata also reaches cards_sets because SetMetadata.extract
      # reads from all Scryfall rows, not the arena_id-filtered subset.
      set = Cards.get_set_by_code("SOS")
      assert set.name == "Secrets of Strixhaven"
      assert set.released_at == ~D[2026-04-24]
    end

    test "regression: tokens get MTGA-only data even when (set, number) collides with parent" do
      # MTGA assigns the parent card's (set, number) to its tokens
      # (e.g. SOS#1 is both 'The Dawning Archaic' AND a 'Copy' token).
      # If Pairing didn't skip tokens, the token row would be enriched
      # with the parent card's Scryfall data.
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 92_100,
        name: "Copy",
        expansion_code: "SOS",
        collector_number: "001",
        types: "2",
        rarity: 0,
        is_token: true
      })

      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-sos-parent",
        arena_id: nil,
        name: "The Dawning Archaic",
        type_line: "Legendary Creature — Wizard",
        color_identity: "WUB",
        rarity: "mythic",
        set_code: "sos",
        collector_number: "001"
      })

      assert {:ok, _} = Synthesize.run([])

      token = Cards.get_by_arena_id(92_100)
      # Parent's data MUST NOT leak into the token row.
      assert token.name == "Copy"
      assert token.color_identity == ""
      assert token.rarity == "token"
    end

    test "is idempotent (re-running yields same state)" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_004,
        name: "Idempotent",
        expansion_code: "FDN",
        collector_number: "200",
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
        collector_number: "300",
        rarity: "common"
      })

      assert {:ok, _} = Synthesize.run([])

      assert Cards.get_set_by_code("FDN") != nil
    end

    test "leaves released_at nil for sets with no Scryfall data (MTGA-only)" do
      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_014,
        name: "MTGA Solo Set",
        expansion_code: "OBSCURE",
        collector_number: "001",
        types: "2",
        rarity: 4
      })

      assert {:ok, _} = Synthesize.run([])

      set = Cards.get_set_by_code("OBSCURE")
      assert set != nil
      assert set.name == "OBSCURE"
      assert set.released_at == nil
    end

    test "skips Scryfall token rows in the rotated pass" do
      # A Scryfall token row with arena_id and no MTGA equivalent should
      # NOT enter cards_cards via the rotated pass. The Pairing-side
      # token guard handles MTGA-side tokens; this guards the other side.
      Scry2.TestFactory.create_scryfall_card(%{
        scryfall_id: "syn-rotated-token",
        arena_id: 80_020,
        name: "Spirit Token",
        type_line: "Token Creature — Spirit",
        set_code: "tsos",
        collector_number: "001",
        rarity: "common",
        layout: "token"
      })

      assert {:ok, _} = Synthesize.run([])

      assert Cards.get_by_arena_id(80_020) == nil
    end

    test "broadcasts cards_updates with the synthesised count" do
      Scry2.Topics.subscribe(Scry2.Topics.cards_updates())

      Scry2.TestFactory.create_mtga_card(%{
        arena_id: 80_006,
        name: "Broadcast",
        expansion_code: "FDN",
        collector_number: "400",
        types: "2",
        rarity: 2
      })

      {:ok, _} = Synthesize.run([])

      assert_receive {:cards_refreshed, _count}
    end
  end
end
