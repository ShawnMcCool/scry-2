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
  end
end
