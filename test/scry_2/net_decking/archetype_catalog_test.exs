defmodule Scry2.NetDecking.ArchetypeCatalogTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.ArchetypeCatalog
  alias Scry2.NetDecking.Buildability.{Result, Section}
  alias Scry2.NetDecking.Deck

  @threshold 0.7
  @zero_cost {0, 0, 0, 0, 0}

  defp deck(id, attrs) do
    struct!(Deck, Map.merge(%{id: id, name: "Deck #{id}"}, Map.new(attrs)))
  end

  defp result(status, sort_key) do
    section = %Section{
      wildcard_cost: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      shortfall: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      owned_pct: 1.0,
      total_copies: 60,
      missing_copies: 0
    }

    %Result{status: status, maindeck: section, sideboard: section, sort_key: sort_key}
  end

  defp scored(id, attrs, status, sort_key, signature_ids) do
    %{
      deck: deck(id, attrs),
      result: result(status, sort_key),
      signature_set: MapSet.new(signature_ids)
    }
  end

  describe "build/2 — grouping and tier membership" do
    test "groups by archetype_name; a group's tier is its best variant status" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Izzet Prowess"}, :buildable, @zero_cost, [1, 2, 3]),
            scored(2, %{archetype_name: "Izzet Prowess"}, :craftable, {0, 2, 0, 0, 2}, [7, 8, 9]),
            scored(3, %{archetype_name: "Dimir Midrange"}, :craftable, {0, 1, 0, 0, 1}, [11, 12]),
            scored(4, %{archetype_name: "Dimir Midrange"}, :short, {2, 4, 0, 0, 6}, [14, 15]),
            scored(5, %{archetype_name: "Domain Overlords"}, :short, {3, 6, 0, 0, 9}, [21, 22])
          ],
          @threshold
        )

      assert [%{archetype_name: "Izzet Prowess"} = prowess] = catalog.buildable
      assert [%{archetype_name: "Dimir Midrange"} = dimir] = catalog.craftable
      assert [%{archetype_name: "Domain Overlords"}] = catalog.short

      assert prowess.status == :buildable
      assert prowess.tally == %{buildable: 1, craftable: 1, short: 0}
      assert dimir.status == :craftable
      assert dimir.tally == %{buildable: 0, craftable: 1, short: 1}
    end

    test "an archetype appears in exactly one tier" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Izzet Prowess"}, :buildable, @zero_cost, [1, 2]),
            scored(2, %{archetype_name: "Izzet Prowess"}, :short, {4, 8, 0, 0, 12}, [5, 6])
          ],
          @threshold
        )

      assert length(catalog.buildable) == 1
      assert catalog.craftable == []
      assert catalog.short == []
    end

    test "empty corpus yields empty tiers" do
      assert ArchetypeCatalog.build([], @threshold) ==
               %{buildable: [], craftable: [], short: []}
    end
  end

  describe "build/2 — variants (clustering inside a group)" do
    test "near-identical lists collapse into one variant counted ×N, cheapest as representative" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Izzet Prowess"}, :short, {1, 2, 0, 0, 3}, [1, 2, 3]),
            scored(2, %{archetype_name: "Izzet Prowess"}, :buildable, @zero_cost, [1, 2, 3])
          ],
          @threshold
        )

      assert [%{variants: [variant]} = group] = catalog.buildable
      assert variant.count == 2
      assert variant.deck.id == 2
      assert variant.result.status == :buildable
      assert group.list_count == 2
    end

    test "variants order buildable → craftable → short, best finish inside a status" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Izzet Prowess", placement: 1}, :short, {1, 2, 0, 0, 3}, [
              1,
              2
            ]),
            scored(2, %{archetype_name: "Izzet Prowess", placement: 5}, :buildable, @zero_cost, [
              4,
              5
            ]),
            scored(3, %{archetype_name: "Izzet Prowess", placement: 2}, :buildable, @zero_cost, [
              7,
              8
            ]),
            scored(
              4,
              %{archetype_name: "Izzet Prowess", placement: 3},
              :craftable,
              {0, 1, 0, 0, 1},
              [10, 11]
            )
          ],
          @threshold
        )

      assert [%{variants: variants}] = catalog.buildable
      assert Enum.map(variants, & &1.deck.id) == [3, 2, 4, 1]
    end

    test "best_finish_deck considers every member list, not just representatives" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Izzet Prowess"}, :buildable, @zero_cost, [1, 2, 3]),
            scored(
              2,
              %{archetype_name: "Izzet Prowess", placement: 1},
              :short,
              {1, 2, 0, 0, 3},
              [1, 2, 3]
            )
          ],
          @threshold
        )

      assert [%{best_finish_deck: %Deck{id: 2, placement: 1}}] = catalog.buildable
    end
  end

  describe "build/2 — tier ordering" do
    test "the buildable tier orders by best finish; unranked groups last" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(
              1,
              %{archetype_name: "Golgari Midrange", placement: 3},
              :buildable,
              @zero_cost,
              [
                1,
                2
              ]
            ),
            scored(2, %{archetype_name: "Mono-Red Aggro", placement: 1}, :buildable, @zero_cost, [
              4,
              5
            ]),
            scored(3, %{archetype_name: "Boros Convoke"}, :buildable, @zero_cost, [7, 8])
          ],
          @threshold
        )

      assert Enum.map(catalog.buildable, & &1.archetype_name) ==
               ["Mono-Red Aggro", "Golgari Midrange", "Boros Convoke"]
    end

    test "craftable and short tiers order cheapest build first" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Azorius Control"}, :craftable, {1, 0, 0, 0, 1}, [1, 2]),
            scored(2, %{archetype_name: "Esper Pixie"}, :craftable, {0, 2, 0, 0, 2}, [4, 5]),
            scored(3, %{archetype_name: "Jeskai Oculus"}, :short, {4, 8, 0, 0, 12}, [7, 8]),
            scored(4, %{archetype_name: "Temur Otters"}, :short, {2, 5, 0, 0, 7}, [10, 11])
          ],
          @threshold
        )

      assert Enum.map(catalog.craftable, & &1.archetype_name) ==
               ["Esper Pixie", "Azorius Control"]

      assert Enum.map(catalog.short, & &1.archetype_name) ==
               ["Temur Otters", "Jeskai Oculus"]
    end

    test "a group's cheapest_sort_key is its cheapest variant's" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: "Esper Pixie"}, :craftable, {0, 2, 0, 0, 2}, [1, 2]),
            scored(2, %{archetype_name: "Esper Pixie"}, :short, {3, 6, 0, 0, 9}, [4, 5])
          ],
          @threshold
        )

      assert [%{cheapest_sort_key: {0, 2, 0, 0, 2}}] = catalog.craftable
    end
  end

  describe "build/2 — unclassified decks" do
    test "an unclassified near-duplicate of a classified list joins that archetype's group" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(
              1,
              %{archetype_name: "Izzet Spellementals"},
              :short,
              {1, 2, 0, 0, 3},
              [1, 2, 3, 4, 5, 6, 7]
            ),
            # Same list with one swap (Jaccard 6/8 = 0.75) — the classifier
            # missed it (nil), but it is the same deck and must not spawn its
            # own synthetic archetype.
            scored(
              2,
              %{archetype_name: nil},
              :craftable,
              {0, 1, 0, 0, 1},
              [1, 2, 3, 4, 5, 6, 8]
            )
          ],
          @threshold
        )

      assert [group] = catalog.craftable
      assert group.archetype_name == "Izzet Spellementals"
      assert group.list_count == 2
      assert catalog.short == []
    end

    test "nil-archetype decks form per-cluster groups with a nil name" do
      catalog =
        ArchetypeCatalog.build(
          [
            scored(1, %{archetype_name: nil}, :short, {1, 2, 0, 0, 3}, [1, 2, 3]),
            scored(2, %{archetype_name: nil}, :short, {1, 3, 0, 0, 4}, [1, 2, 3]),
            scored(3, %{archetype_name: nil}, :short, {2, 4, 0, 0, 6}, [7, 8, 9])
          ],
          @threshold
        )

      assert length(catalog.short) == 2
      assert Enum.all?(catalog.short, &is_nil(&1.archetype_name))
      assert catalog.short |> Enum.map(& &1.list_count) |> Enum.sort() == [1, 2]
    end
  end
end
