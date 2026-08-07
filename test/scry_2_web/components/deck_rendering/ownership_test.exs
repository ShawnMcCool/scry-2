defmodule Scry2Web.DeckRendering.OwnershipTest do
  use ExUnit.Case, async: true

  alias Scry2.Buildability.Assessment
  alias Scry2.Buildability.CardRow
  alias Scry2.Buildability.Result
  alias Scry2.Buildability.Section
  alias Scry2Web.DeckRendering.Ownership

  defp row(fields) do
    struct!(
      %CardRow{
        arena_id: 1,
        name: "Opt",
        rarity: "common",
        needed: 1,
        owned: 1,
        missing: 0,
        free?: false
      },
      fields
    )
  end

  defp empty_section do
    %Section{
      wildcard_cost: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      shortfall: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      owned_pct: 1.0,
      total_copies: 0,
      missing_copies: 0
    }
  end

  defp assessment(main_rows, side_rows \\ [], collection_known? \\ true) do
    %Assessment{
      result: %Result{
        status: :buildable,
        maindeck: empty_section(),
        sideboard: empty_section(),
        sort_key: {0, 0, 0, 0, 0}
      },
      main_rows: main_rows,
      side_rows: side_rows,
      wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
      collection_known?: collection_known?
    }
  end

  describe "rows_index/1" do
    test "indexes an assessment's maindeck and sideboard rows by arena_id" do
      index =
        assessment(
          [row(arena_id: 1, name: "Lightning Bolt"), row(arena_id: 2, name: "Mountain")],
          [row(arena_id: 3, name: "Negate", owned: 0, missing: 2, needed: 2)]
        )
        |> Ownership.rows_index()

      assert map_size(index) == 3
      assert index[1].name == "Lightning Bolt"
      assert index[3].missing == 2
    end

    test "skips rows without a resolved arena_id" do
      assert Ownership.rows_index(assessment([row(arena_id: nil)])) == %{}
    end

    test "passes an already-indexed map through, and nil to empty" do
      index = %{7 => row(arena_id: 7)}

      assert Ownership.rows_index(index) == index
      assert Ownership.rows_index(nil) == %{}
    end

    test "an unknown collection yields no annotation at all" do
      assert Ownership.rows_index(assessment([row(arena_id: 1)], [], false)) == %{}
    end
  end

  describe "count_entry/1" do
    # The count entry feeding the deck view's gutter rail / badge pill
    # (UIDR-015): counts never cover the card; ownership carries the tone.
    defp entry_for(rows, card), do: Ownership.count_entry(rows).(card)

    test "fully-owned single copies render nothing — blank means one" do
      rows = %{1 => row(needed: 1, owned: 1, missing: 0)}

      assert entry_for(rows, %{arena_id: 1, count: 1}) == nil
    end

    test "fully-owned piles render the count in the owned tone" do
      rows = %{1 => row(needed: 4, owned: 4, missing: 0)}

      assert %{label: "4", class: "text-success"} = entry_for(rows, %{arena_id: 1, count: 4})
    end

    test "missing cards always show their count, warning-toned, with the ownership tooltip" do
      rows = %{1 => row(name: "Namor", needed: 1, owned: 0, missing: 1)}

      assert %{label: "1", class: "text-warning", title: "Namor — 0/1 owned"} =
               entry_for(rows, %{arena_id: 1, count: 1})
    end

    test "partially-owned piles show the count in the partial tone" do
      rows = %{1 => row(name: "Bolt", needed: 4, owned: 2, missing: 2)}

      assert %{label: "4", class: "text-base-content/60"} =
               entry_for(rows, %{arena_id: 1, count: 4})
    end

    test "basic lands render dimmed with the basic-land tooltip" do
      rows = %{1 => row(name: "Mountain", free?: true, needed: 18, owned: 0, missing: 0)}

      assert %{label: "18", class: "text-base-content/30", title: "Mountain — basic land"} =
               entry_for(rows, %{arena_id: 1, count: 18})
    end

    test "cards without an ownership row fall back to the plain count" do
      assert entry_for(%{}, %{arena_id: 9, count: 1}) == nil
      assert %{label: "3", class: nil, title: nil} = entry_for(%{}, %{arena_id: 9, count: 3})
    end

    test "accepts an assessment directly" do
      assessment = assessment([row(arena_id: 1, name: "Bolt", needed: 4, owned: 0, missing: 4)])

      assert %{label: "4", class: "text-warning"} =
               Ownership.count_entry(assessment).(%{arena_id: 1, count: 4})
    end
  end

  describe "card_class/1" do
    test "tints rows the player is short of" do
      tint = Ownership.card_class(%{1 => row(missing: 2), 2 => row(arena_id: 2, missing: 0)})

      assert tint.(%{arena_id: 1}) == "text-warning"
      assert tint.(%{arena_id: 2}) == nil
      assert tint.(%{arena_id: 99}) == nil
    end
  end

  describe "row_state/1 and row_tone/1" do
    test "classifies a row" do
      assert Ownership.row_state(row(free?: true, owned: 0, missing: 0)) == :free
      assert Ownership.row_state(row(owned: 4, missing: 0)) == :owned
      assert Ownership.row_state(row(owned: 0, missing: 4)) == :missing
      assert Ownership.row_state(row(owned: 2, missing: 2)) == :partial
    end

    test "maps each state to a colour class" do
      for state <- [:free, :owned, :missing, :partial] do
        assert is_binary(Ownership.row_tone(state))
      end

      assert Ownership.row_tone(:owned) == "text-success"
      assert Ownership.row_tone(:missing) == "text-warning"
    end
  end

  describe "title/1" do
    test "describes a row's ownership for tooltips" do
      assert Ownership.title(nil) == nil

      assert Ownership.title(row(name: "Mountain", free?: true, owned: 0, needed: 20)) ==
               "Mountain — basic land"

      assert Ownership.title(row(name: "Lightning Bolt", owned: 2, needed: 4)) ==
               "Lightning Bolt — 2/4 owned"
    end
  end
end
