defmodule Scry2.Collection.CompletionTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.SetRoster
  alias Scry2.Collection.{Completion, Holding}
  alias Scry2.TestFactory

  defp holding(arena_id, count, set_id, rarity) do
    card =
      TestFactory.build_card(%{
        arena_id: arena_id,
        rarity: rarity,
        set_id: set_id
      })

    %Holding{
      arena_id: arena_id,
      count: count,
      card: card,
      copies_to_playset: max(4 - count, 0)
    }
  end

  defp roster(set_id, code, totals) do
    %SetRoster{
      set: TestFactory.build_set(%{id: set_id, code: code}),
      totals: totals
    }
  end

  describe "from_holdings/2" do
    test "computes per-set rarity ratios from owned holdings vs. roster totals" do
      lci_id = 1
      mid_id = 2

      holdings = [
        holding(70_001, 4, lci_id, "common"),
        holding(70_002, 1, lci_id, "common"),
        holding(70_003, 1, lci_id, "rare"),
        holding(70_010, 1, mid_id, "mythic")
      ]

      rosters = %{
        lci_id => roster(lci_id, "LCI", %{"common" => 5, "rare" => 3, "mythic" => 1}),
        mid_id => roster(mid_id, "MID", %{"common" => 10, "rare" => 5, "mythic" => 1})
      }

      [lci, mid] =
        Completion.from_holdings(holdings, rosters)
        |> Enum.sort_by(& &1.set.code)

      assert lci.set.code == "LCI"
      assert lci.owned_unique == 3
      assert lci.total_unique == 9

      assert lci.by_rarity["common"] == %{owned: 2, total: 5}
      assert lci.by_rarity["rare"] == %{owned: 1, total: 3}
      assert lci.by_rarity["mythic"] == %{owned: 0, total: 1}

      assert mid.owned_unique == 1
      assert mid.by_rarity["mythic"] == %{owned: 1, total: 1}
    end

    test "includes sets from the roster even when nothing is owned" do
      rosters = %{
        9 => roster(9, "EMPTY", %{"common" => 3, "rare" => 1})
      }

      [completion] = Completion.from_holdings([], rosters)

      assert completion.set.code == "EMPTY"
      assert completion.owned_unique == 0
      assert completion.total_unique == 4
      assert completion.by_rarity["common"] == %{owned: 0, total: 3}
    end

    test "ignores holdings whose set is not in the rosters map" do
      orphan_set_id = 999
      holdings = [holding(71_001, 2, orphan_set_id, "common")]

      assert Completion.from_holdings(holdings, %{}) == []
    end

    test "returns sets ordered by released_at desc" do
      old = roster(1, "OLD", %{"common" => 1})
      old = put_in(old.set.released_at, ~D[2024-01-01])
      new = roster(2, "NEW", %{"common" => 1})
      new = put_in(new.set.released_at, ~D[2026-01-01])
      mid = roster(3, "MID", %{"common" => 1})
      mid = put_in(mid.set.released_at, ~D[2025-01-01])

      result = Completion.from_holdings([], %{1 => old, 2 => new, 3 => mid})

      assert Enum.map(result, & &1.set.code) == ["NEW", "MID", "OLD"]
    end

    test "orders chronologically when dates differ across day, month, and year" do
      # Regression: `Enum.sort_by(..., :desc)` falls back to term comparison
      # on `%Date{}`, which compares by alphabetical map-key order
      # (`:calendar`, `:day`, `:month`, `:year`). With dates that differ on
      # day-of-month, the buggy comparator returns the wrong order.
      newest = roster(1, "NEW", %{"common" => 1})
      newest = put_in(newest.set.released_at, ~D[2024-09-27])
      middle = roster(2, "MID", %{"common" => 1})
      middle = put_in(middle.set.released_at, ~D[2017-09-29])
      oldest = roster(3, "OLD", %{"common" => 1})
      oldest = put_in(oldest.set.released_at, ~D[2016-09-30])

      result = Completion.from_holdings([], %{1 => newest, 2 => middle, 3 => oldest})

      assert Enum.map(result, & &1.set.code) == ["NEW", "MID", "OLD"]
    end
  end

  describe "completion_ratio/1" do
    test "returns owned_unique / total_unique as a float between 0.0 and 1.0" do
      completion = %Completion{
        set: TestFactory.build_set(%{code: "RATIO"}),
        owned_unique: 7,
        total_unique: 10,
        by_rarity: %{}
      }

      assert Completion.completion_ratio(completion) == 0.7
    end

    test "returns 0.0 for empty rosters" do
      completion = %Completion{
        set: TestFactory.build_set(%{code: "EMPTY"}),
        owned_unique: 0,
        total_unique: 0,
        by_rarity: %{}
      }

      assert Completion.completion_ratio(completion) == 0.0
    end
  end
end
