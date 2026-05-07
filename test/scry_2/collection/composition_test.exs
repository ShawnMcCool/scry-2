defmodule Scry2.Collection.CompositionTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.{Composition, Holding}
  alias Scry2.TestFactory

  defp holding(arena_id, count, card_attrs) do
    card = TestFactory.build_card(Map.merge(%{arena_id: arena_id}, card_attrs))

    %Holding{
      arena_id: arena_id,
      count: count,
      card: card,
      copies_to_playset: max(4 - count, 0)
    }
  end

  describe "from_holdings/1" do
    test "groups by rarity, counting unique cards and total copies" do
      holdings = [
        holding(80_001, 4, %{rarity: "common"}),
        holding(80_002, 2, %{rarity: "common"}),
        holding(80_003, 1, %{rarity: "rare"}),
        holding(80_004, 3, %{rarity: "mythic"})
      ]

      composition = Composition.from_holdings(holdings)

      assert composition.by_rarity == %{
               "common" => %{owned_unique: 2, total_copies: 6},
               "rare" => %{owned_unique: 1, total_copies: 1},
               "mythic" => %{owned_unique: 1, total_copies: 3}
             }
    end

    test "buckets by colour: empty -> C, single -> that colour, 2+ -> M" do
      holdings = [
        holding(81_001, 1, %{color_identity: ""}),
        holding(81_002, 4, %{color_identity: "W"}),
        holding(81_003, 2, %{color_identity: "U"}),
        holding(81_004, 1, %{color_identity: "WU"}),
        holding(81_005, 1, %{color_identity: "WUBRG"})
      ]

      composition = Composition.from_holdings(holdings)

      assert composition.by_colour["C"] == %{owned_unique: 1, total_copies: 1}
      assert composition.by_colour["W"] == %{owned_unique: 1, total_copies: 4}
      assert composition.by_colour["U"] == %{owned_unique: 1, total_copies: 2}
      assert composition.by_colour["M"] == %{owned_unique: 2, total_copies: 2}
    end

    test "buckets by primary type, counting each type the card has" do
      holdings = [
        holding(82_001, 4, %{is_creature: true}),
        holding(82_002, 2, %{is_instant: true}),
        holding(82_003, 1, %{is_creature: true, is_artifact: true}),
        holding(82_004, 3, %{is_land: true})
      ]

      composition = Composition.from_holdings(holdings)

      assert composition.by_type[:creature] == %{owned_unique: 2, total_copies: 5}
      assert composition.by_type[:instant] == %{owned_unique: 1, total_copies: 2}
      assert composition.by_type[:artifact] == %{owned_unique: 1, total_copies: 1}
      assert composition.by_type[:land] == %{owned_unique: 1, total_copies: 3}
    end

    test "totals report unique cards and total copies across the whole collection" do
      holdings = [
        holding(83_001, 4, %{rarity: "common"}),
        holding(83_002, 1, %{rarity: "rare"})
      ]

      composition = Composition.from_holdings(holdings)
      assert composition.total_unique == 2
      assert composition.total_copies == 5
    end

    test "returns an empty composition for []" do
      composition = Composition.from_holdings([])
      assert composition.by_rarity == %{}
      assert composition.by_colour == %{}
      assert composition.by_type == %{}
      assert composition.total_unique == 0
      assert composition.total_copies == 0
    end
  end
end
