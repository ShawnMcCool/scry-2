defmodule Scry2.NetDecking.DeckQualitiesTest do
  use ExUnit.Case, async: true
  alias Scry2.NetDecking.DeckQualities

  describe "color_combo_name/1" do
    test "names mono, guild, shard/wedge, 4c, 5c, colorless" do
      assert DeckQualities.color_combo_name("") == "Colorless"
      assert DeckQualities.color_combo_name("R") == "Mono-Red"
      assert DeckQualities.color_combo_name("WR") == "Boros"
      assert DeckQualities.color_combo_name("UR") == "Izzet"
      assert DeckQualities.color_combo_name("WUR") == "Jeskai"
      assert DeckQualities.color_combo_name("BRG") == "Jund"
      assert DeckQualities.color_combo_name("WUBR") == "4-color"
      assert DeckQualities.color_combo_name("WUBRG") == "5-color"
    end
  end

  describe "deck_color_identity/2" do
    test "unions color_identity across the maindeck in WUBRG order" do
      cards = %{
        1 => %{color_identity: "R"},
        2 => %{color_identity: "W"},
        3 => %{color_identity: ""},
        4 => %{color_identity: nil}
      }

      entries = [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 2}, %{arena_id: 3, count: 1}]
      assert DeckQualities.deck_color_identity(entries, cards) == "WR"
    end

    test "no colored cards yields empty string" do
      cards = %{1 => %{color_identity: ""}}
      assert DeckQualities.deck_color_identity([%{arena_id: 1, count: 1}], cards) == ""
    end
  end

  describe "signature_arena_ids/3" do
    test "top-n nonland cards by rarity then mana value then arena_id" do
      cards = %{
        10 => %{rarity: "mythic", mana_value: 5, is_land: false},
        11 => %{rarity: "rare", mana_value: 6, is_land: false},
        12 => %{rarity: "rare", mana_value: 2, is_land: false},
        13 => %{rarity: "common", mana_value: 1, is_land: false},
        99 => %{rarity: "rare", mana_value: 9, is_land: true}
      }

      entries = Enum.map([10, 11, 12, 13, 99], &%{arena_id: &1, count: 1})
      assert DeckQualities.signature_arena_ids(entries, cards, 4) == [10, 11, 12, 13]
    end

    test "returns fewer than n when not enough nonland cards; all-land -> []" do
      cards = %{1 => %{rarity: "rare", mana_value: 9, is_land: true}}
      assert DeckQualities.signature_arena_ids([%{arena_id: 1, count: 1}], cards, 4) == []
    end
  end

  describe "archetype_signature_ids/4" do
    # "The card this archetype plays that others don't" (UIDR-017):
    # within-group play (avg copies per list) discounted by how many other
    # archetype groups play the card; rarity, then arena_id break ties.

    test "a distinctive card outranks a format staple played everywhere" do
      cards = %{
        # Stormchaser's Talent stand-in: rare, only this archetype plays it
        1 => %{rarity: "rare", is_land: false},
        # Into the Flood Maw stand-in: rare, five other archetypes play it
        2 => %{rarity: "rare", is_land: false}
      }

      member_entries = [
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}],
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}]
      ]

      groups_playing = %{1 => 1, 2 => 6}

      assert DeckQualities.archetype_signature_ids(member_entries, cards, groups_playing, 2) ==
               [1, 2]
    end

    test "rarity breaks a distinctiveness tie" do
      cards = %{
        # Monastery Swiftspear stand-in: common, exclusive, 4x
        1 => %{rarity: "common", is_land: false},
        # Stormchaser's Talent stand-in: rare, exclusive, 4x
        2 => %{rarity: "rare", is_land: false}
      }

      member_entries = [[%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}]]
      groups_playing = %{1 => 1, 2 => 1}

      assert DeckQualities.archetype_signature_ids(member_entries, cards, groups_playing, 2) ==
               [2, 1]
    end

    test "more copies beat fewer when both are exclusive and same rarity" do
      cards = %{
        # Talent stand-in: 4x in both lists
        1 => %{rarity: "rare", is_land: false},
        # Cori-Steel Cutter stand-in: 3x in both lists
        2 => %{rarity: "rare", is_land: false}
      }

      member_entries = [
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 3}],
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 3}]
      ]

      groups_playing = %{1 => 1, 2 => 1}

      assert DeckQualities.archetype_signature_ids(member_entries, cards, groups_playing, 2) ==
               [1, 2]
    end

    test "a flashy exclusive 1-of mythic loses to the exclusive 4-of rare" do
      cards = %{
        1 => %{rarity: "mythic", is_land: false},
        2 => %{rarity: "rare", is_land: false}
      }

      member_entries = [[%{arena_id: 1, count: 1}, %{arena_id: 2, count: 4}]]
      groups_playing = %{1 => 1, 2 => 1}

      assert DeckQualities.archetype_signature_ids(member_entries, cards, groups_playing, 2) ==
               [2, 1]
    end

    test "lands and unknown cards are excluded; n caps the result" do
      cards = %{
        1 => %{rarity: "rare", is_land: false},
        2 => %{rarity: "rare", is_land: true}
      }

      member_entries = [
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}, %{arena_id: 99, count: 4}]
      ]

      groups_playing = %{1 => 1, 2 => 1, 99 => 1}

      assert DeckQualities.archetype_signature_ids(member_entries, cards, groups_playing, 4) ==
               [1]
    end

    test "no member decks yields no signature" do
      assert DeckQualities.archetype_signature_ids([], %{}, %{}, 4) == []
    end
  end

  describe "archetype_core/2" do
    # The archetype's typical list (UIDR-017): cards in at least half the
    # member lists, at their most common copy count.

    test "keeps cards played in at least half the lists at their modal count" do
      member_entries = [
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 2}],
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 3}, %{arena_id: 3, count: 1}],
        [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 3}, %{arena_id: 9, count: 1}],
        [%{arena_id: 1, count: 3}, %{arena_id: 2, count: 3}]
      ]

      core = DeckQualities.archetype_core(member_entries, 0.5)

      # Card 1 in 4/4 lists, modal 4x; card 2 in 4/4 lists, modal 3x;
      # cards 3 and 9 in 1/4 lists each — below the presence bar.
      assert Enum.sort_by(core, & &1.arena_id) == [
               %{arena_id: 1, count: 4},
               %{arena_id: 2, count: 3}
             ]
    end

    test "a modal-count tie resolves to the higher count" do
      member_entries = [
        [%{arena_id: 1, count: 2}],
        [%{arena_id: 1, count: 3}]
      ]

      assert DeckQualities.archetype_core(member_entries, 0.5) == [%{arena_id: 1, count: 3}]
    end

    test "a single-list group's core is that list" do
      member_entries = [[%{arena_id: 1, count: 4}, %{arena_id: 2, count: 18}]]

      assert DeckQualities.archetype_core(member_entries, 0.5) |> Enum.sort_by(& &1.arena_id) ==
               [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 18}]
    end

    test "no member lists yields an empty core" do
      assert DeckQualities.archetype_core([], 0.5) == []
    end
  end

  describe "core_deltas/2" do
    test "reports the variant's differences from the core, additions first" do
      core = [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 3}, %{arena_id: 3, count: 2}]

      variant = [
        # unchanged
        %{arena_id: 1, count: 4},
        # one fewer than core
        %{arena_id: 2, count: 2},
        # not in the core at all
        %{arena_id: 7, count: 2}
        # card 3 cut entirely
      ]

      assert DeckQualities.core_deltas(variant, core) == [
               %{arena_id: 7, delta: 2},
               %{arena_id: 2, delta: -1},
               %{arena_id: 3, delta: -2}
             ]
    end

    test "a variant identical to the core has no deltas" do
      core = [%{arena_id: 1, count: 4}]
      assert DeckQualities.core_deltas([%{arena_id: 1, count: 4}], core) == []
    end
  end

  describe "newest_set_code/3" do
    test "newest set (by released_at) among sets with >=2 cards" do
      cards = %{
        1 => %{set_id: 100},
        2 => %{set_id: 100},
        3 => %{set_id: 200},
        4 => %{set_id: 200},
        5 => %{set_id: 300}
      }

      sets = %{
        100 => %{code: "OLD", released_at: ~D[2025-01-01]},
        200 => %{code: "NEW", released_at: ~D[2026-04-24]},
        300 => %{code: "SOLO", released_at: ~D[2026-12-01]}
      }

      entries = Enum.map(1..5, &%{arena_id: &1, count: 1})
      assert DeckQualities.newest_set_code(entries, cards, sets) == "NEW"
    end

    test "nil when no set has >=2 cards" do
      cards = %{1 => %{set_id: 100}, 2 => %{set_id: 200}}

      sets = %{
        100 => %{code: "A", released_at: ~D[2026-01-01]},
        200 => %{code: "B", released_at: ~D[2026-02-01]}
      }

      entries = [%{arena_id: 1, count: 1}, %{arena_id: 2, count: 1}]
      assert DeckQualities.newest_set_code(entries, cards, sets) == nil
    end

    test "ignores sets with a nil released_at (no Date.compare crash)" do
      cards = %{
        1 => %{set_id: 100},
        2 => %{set_id: 100},
        3 => %{set_id: 200},
        4 => %{set_id: 200}
      }

      sets = %{
        100 => %{code: "DATED", released_at: ~D[2026-04-24]},
        200 => %{code: "UNDATED", released_at: nil}
      }

      entries = Enum.map(1..4, &%{arena_id: &1, count: 1})
      assert DeckQualities.newest_set_code(entries, cards, sets) == "DATED"
    end
  end
end
