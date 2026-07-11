defmodule Scry2Web.DeckRenderingTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DeckRendering
  alias Scry2Web.DeckRendering.ViewSpec

  # Reference card lookup shared across tests.
  defp cards_by_arena_id do
    %{
      1 => %{name: "Lightning Bolt", types: "Instant", mana_value: 1},
      2 => %{name: "Counterspell", types: "Instant", mana_value: 2},
      3 => %{name: "Mountain", types: "Basic Land", mana_value: 0},
      4 => %{name: "Emrakul", types: "Creature", mana_value: 15},
      5 => %{name: "Grim Tutor", types: "Sorcery", mana_value: 3},
      6 => %{name: "Sol Ring", types: "Artifact", mana_value: 1}
    }
  end

  describe "ViewSpec" do
    test "defaults describe a piled image wrap with the standard splay depth" do
      spec = %ViewSpec{}

      assert spec.group_by == :none
      assert spec.display == :images
      assert spec.piling == :piled
      assert spec.layout == :wrap
      assert spec.splay_depth == 0.25
    end
  end

  describe "snapshot normalization" do
    test "card_count reads map snapshots, bare lists, and defaults count to 1" do
      assert DeckRendering.card_count(%{"cards" => [%{"arena_id" => 1, "count" => 4}]}) == 4
      assert DeckRendering.card_count([%{"arena_id" => 1, "count" => 4}]) == 4
      assert DeckRendering.card_count(%{"cards" => [%{"arena_id" => 1}]}) == 1
      assert DeckRendering.card_count(nil) == 0
      assert DeckRendering.card_count(%{}) == 0
    end

    test "cards accepts a bare list of arena_ids (draft pool shape)" do
      assert DeckRendering.cards([1, 2, 1]) == [
               %{arena_id: 1, count: 1},
               %{arena_id: 2, count: 1},
               %{arena_id: 1, count: 1}
             ]
    end

    test "arena_ids extracts ids from any snapshot shape" do
      assert DeckRendering.arena_ids(%{"cards" => [%{"arena_id" => 1}, %{arena_id: 2}]}) == [1, 2]
      assert DeckRendering.arena_ids([%{"arena_id" => 3}]) == [3]
      assert DeckRendering.arena_ids([7, 8]) == [7, 8]
      assert DeckRendering.arena_ids(nil) == []
    end

    test "empty? is true only when both snapshots have no cards" do
      refute DeckRendering.empty?(%{"cards" => [%{"arena_id" => 1}]}, nil)
      refute DeckRendering.empty?(nil, %{"cards" => [%{"arena_id" => 1}]})
      assert DeckRendering.empty?(nil, nil)
      assert DeckRendering.empty?(%{"cards" => []}, %{"cards" => []})
    end
  end

  describe "sections/3 grouped by :type" do
    test "groups by card type in canonical order, cards sorted by mana value" do
      main_deck = %{
        "cards" => [
          %{"arena_id" => 5, "count" => 2},
          %{"arena_id" => 2, "count" => 2},
          %{"arena_id" => 1, "count" => 4},
          %{"arena_id" => 3, "count" => 20}
        ]
      }

      spec = %ViewSpec{group_by: :type}
      sections = DeckRendering.sections(main_deck, spec, cards_by_arena_id())
      labels = Enum.map(sections, fn {label, _} -> label end)

      assert labels == ["Instants", "Sorceries", "Lands"]

      {_, instants} = List.first(sections)
      assert Enum.map(instants, & &1.name) == ["Lightning Bolt", "Counterspell"]
    end

    test "piled duplicates with the same name merge into one entry" do
      main_deck = %{
        "cards" => [
          %{"arena_id" => 100, "count" => 1},
          %{"arena_id" => 200, "count" => 1}
        ]
      }

      lookup = %{
        100 => %{name: "Breeding Pool", types: "Land", mana_value: 0},
        200 => %{name: "Breeding Pool", types: "Land", mana_value: 0}
      }

      [{"Lands", lands}] =
        DeckRendering.sections(main_deck, %ViewSpec{group_by: :type}, lookup)

      assert [%{name: "Breeding Pool", count: 2}] = lands
    end
  end

  describe "sections/3 grouped by :mana_value" do
    test "groups by mana value 0-7+, lands last" do
      main_deck = %{
        "cards" => [
          %{"arena_id" => 1, "count" => 4},
          %{"arena_id" => 2, "count" => 2},
          %{"arena_id" => 3, "count" => 24}
        ]
      }

      spec = %ViewSpec{group_by: :mana_value}

      labels =
        DeckRendering.sections(main_deck, spec, cards_by_arena_id())
        |> Enum.map(fn {label, _} -> label end)

      assert labels == ["1", "2", "Land"]
    end

    test "mana values of 7 or more group under 7+, unknown cards under 0" do
      spec = %ViewSpec{group_by: :mana_value}

      [{label, _}] =
        DeckRendering.sections(
          %{"cards" => [%{"arena_id" => 4, "count" => 1}]},
          spec,
          cards_by_arena_id()
        )

      assert label == "7+"

      [{label, [card]}] =
        DeckRendering.sections(%{"cards" => [%{"arena_id" => 999, "count" => 1}]}, spec, %{})

      assert label == "0"
      assert card.count == 1
    end
  end

  describe "sections/3 grouped by :broad_type" do
    test "uses the condensed draft-pool vocabulary in canonical order" do
      pool = [1, 5, 6, 3, 4]

      spec = %ViewSpec{group_by: :broad_type, piling: :spread}

      labels =
        DeckRendering.sections(pool, spec, cards_by_arena_id())
        |> Enum.map(fn {label, _} -> label end)

      assert labels == [
               "Creatures",
               "Instants & Sorceries",
               "Artifacts & Enchantments",
               "Lands"
             ]
    end

    test "cards with no lookup entry fall under Other" do
      [{label, _}] =
        DeckRendering.sections([999], %ViewSpec{group_by: :broad_type, piling: :spread}, %{})

      assert label == "Other"
    end
  end

  describe "sections/3 with group_by :none" do
    test "returns a single unlabeled section" do
      main_deck = %{"cards" => [%{"arena_id" => 1, "count" => 4}]}

      assert [{nil, [card]}] =
               DeckRendering.sections(main_deck, %ViewSpec{}, cards_by_arena_id())

      assert card.name == "Lightning Bolt"
    end

    test "returns no sections for an empty snapshot" do
      assert DeckRendering.sections(nil, %ViewSpec{}, %{}) == []
      assert DeckRendering.sections(%{"cards" => []}, %ViewSpec{}, %{}) == []
    end
  end

  describe "piling" do
    test ":spread expands counts into individual copies without merging" do
      main_deck = %{"cards" => [%{"arena_id" => 1, "count" => 3}]}

      [{nil, copies}] =
        DeckRendering.sections(main_deck, %ViewSpec{piling: :spread}, cards_by_arena_id())

      assert length(copies) == 3
      assert Enum.all?(copies, &(&1.count == 1))
    end

    test ":piled keeps one entry per name with the summed count" do
      main_deck = %{"cards" => [%{"arena_id" => 1, "count" => 3}]}

      [{nil, [card]}] =
        DeckRendering.sections(main_deck, %ViewSpec{piling: :piled}, cards_by_arena_id())

      assert card.count == 3
    end
  end

  describe "order" do
    test ":natural preserves input order in an ungrouped section" do
      pack = [2, 3, 1]

      [{nil, cards}] =
        DeckRendering.sections(
          pack,
          %ViewSpec{piling: :spread, order: :natural},
          cards_by_arena_id()
        )

      assert Enum.map(cards, & &1.arena_id) == [2, 3, 1]
    end

    test ":sorted (default) orders an ungrouped section by mana value then name" do
      pack = [2, 3, 1]

      [{nil, cards}] =
        DeckRendering.sections(pack, %ViewSpec{piling: :spread}, cards_by_arena_id())

      assert Enum.map(cards, & &1.arena_id) == [3, 1, 2]
    end

    test ":natural preserves input order in resolved_cards" do
      snapshot = %{
        "cards" => [%{"arena_id" => 2, "count" => 1}, %{"arena_id" => 1, "count" => 1}]
      }

      names =
        DeckRendering.resolved_cards(snapshot, %ViewSpec{order: :natural}, cards_by_arena_id())
        |> Enum.map(& &1.name)

      assert names == ["Counterspell", "Lightning Bolt"]
    end
  end

  describe "resolved_cards/3" do
    test "resolves, piles, and sorts a snapshot by mana value then name" do
      sideboard = %{
        "cards" => [
          %{"arena_id" => 30, "count" => 1},
          %{"arena_id" => 10, "count" => 2},
          %{"arena_id" => 20, "count" => 3}
        ]
      }

      lookup = %{
        10 => %{name: "Negate", types: "Instant", mana_value: 2},
        20 => %{name: "Disdainful Stroke", types: "Instant", mana_value: 2},
        30 => %{name: "Tormod's Crypt", types: "Artifact", mana_value: 0}
      }

      names =
        DeckRendering.resolved_cards(sideboard, %ViewSpec{}, lookup) |> Enum.map(& &1.name)

      assert names == ["Tormod's Crypt", "Disdainful Stroke", "Negate"]
    end

    test "falls back to stringified arena_id for unknown cards" do
      [card] =
        DeckRendering.resolved_cards(%{"cards" => [%{"arena_id" => 99_999}]}, %ViewSpec{}, %{})

      assert card.name == "99999"
    end
  end

  describe "mana curve" do
    test "mana_curve returns a frequency map excluding lands, capped at 7" do
      main_deck = %{
        "cards" => [
          %{"arena_id" => 1, "count" => 4},
          %{"arena_id" => 2, "count" => 2},
          %{"arena_id" => 3, "count" => 24},
          %{"arena_id" => 4, "count" => 1}
        ]
      }

      assert DeckRendering.mana_curve(main_deck, cards_by_arena_id()) == %{
               1 => 4,
               2 => 2,
               7 => 1
             }
    end

    test "curve_series encodes the 0-7+ labels for the chart hook" do
      main_deck = %{"cards" => [%{"arena_id" => 1, "count" => 4}]}

      decoded = DeckRendering.curve_series(main_deck, cards_by_arena_id()) |> Jason.decode!()

      assert Enum.find(decoded, fn [label, _] -> label == "1" end) == ["1", 4]
      assert Enum.find(decoded, fn [label, _] -> label == "7+" end) == ["7+", 0]
    end
  end

  describe "card names and types" do
    test "card_name resolves from the lookup with fallbacks" do
      assert DeckRendering.card_name(1, cards_by_arena_id()) == "Lightning Bolt"
      assert DeckRendering.card_name(99_999, %{}) == "99999"
      assert DeckRendering.card_name(nil, %{}) == "Unknown"
    end

    test "type_label classifies card data" do
      assert DeckRendering.type_label(%{types: "Legendary Creature"}) == "Creatures"
      assert DeckRendering.type_label(%{types: "Basic Land"}) == "Lands"
      assert DeckRendering.type_label(nil) == "Unknown"
    end

    test "type_order sorts creatures before lands before unknown" do
      assert DeckRendering.type_order("Creatures") < DeckRendering.type_order("Lands")
      assert DeckRendering.type_order("Lands") < DeckRendering.type_order("Unknown")
    end
  end

  describe "stack layout math" do
    test "stack_aspect_ratio at the default splay depth" do
      assert DeckRendering.stack_aspect_ratio(0, 0.25) == "1"
      assert DeckRendering.stack_aspect_ratio(1, 0.25) == "488 / 680"
      assert DeckRendering.stack_aspect_ratio(2, 0.25) == "488 / #{Float.round(680 * 1.25, 1)}"
    end

    test "splay depth controls the distance between stacked card tops" do
      shallow = DeckRendering.stack_top_percent(1, 4, 0.1)
      deep = DeckRendering.stack_top_percent(1, 4, 0.5)

      assert shallow > 0.0
      assert deep > shallow
    end

    test "stack_top_percent starts at 0 and increases per card" do
      assert DeckRendering.stack_top_percent(0, 4, 0.25) == 0.0

      assert DeckRendering.stack_top_percent(1, 4, 0.25) <
               DeckRendering.stack_top_percent(2, 4, 0.25)
    end
  end
end
