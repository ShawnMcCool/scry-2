defmodule Scry2.Buildability.ScoreCardListTest do
  use ExUnit.Case, async: true

  alias Scry2.Buildability.CardRow
  alias Scry2.Buildability.CollectionPosition
  alias Scry2.Buildability.Result
  alias Scry2.Buildability.ScoreCardList
  alias Scry2.Buildability.Section

  defp position(fields) do
    struct!(
      %CollectionPosition{
        owned: %{},
        wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
        rarities: %{},
        free_arena_ids: MapSet.new(),
        collection_known?: true
      },
      fields
    )
  end

  test "default_free_ids returns basic-land arena_ids, treating nameless cards as non-basic" do
    cards = %{
      1 => %{name: "Mountain"},
      2 => %{name: "Lightning Bolt"},
      3 => %{name: "Forest"},
      4 => %{}
    }

    assert ScoreCardList.default_free_ids(cards) == MapSet.new([1, 3])
  end

  test "card_shortage returns missing copies, excluding free arena_ids" do
    deck = [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 4}, %{arena_id: 99, count: 8}]
    owned = %{1 => 4, 2 => 1}
    free = MapSet.new([99])

    assert ScoreCardList.card_shortage(deck, owned, free) == [{2, 3}]
  end

  test "rarity_buckets sums missing copies by rarity" do
    shortages = [{2, 3}, {3, 2}, {4, 1}]
    rarities = %{2 => "uncommon", 3 => "rare", 4 => "rare"}

    assert ScoreCardList.rarity_buckets(shortages, rarities) ==
             %{common: 0, uncommon: 3, rare: 3, mythic: 0}
  end

  test "affordability returns per-rarity shortfall, never paying across rarities" do
    cost = %{common: 0, uncommon: 2, rare: 3, mythic: 1}
    wildcards = %{common: 10, uncommon: 5, rare: 1, mythic: 0}

    assert ScoreCardList.affordability(cost, wildcards) ==
             %{common: 0, uncommon: 0, rare: 2, mythic: 1}
  end

  test "classify_status: buildable when cost is zero" do
    assert ScoreCardList.classify_status(%{common: 0, uncommon: 0, rare: 0, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 0,
             mythic: 0
           }) == :buildable
  end

  test "classify_status: craftable when cost > 0 but shortfall is zero" do
    assert ScoreCardList.classify_status(%{common: 0, uncommon: 2, rare: 0, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 0,
             mythic: 0
           }) == :craftable
  end

  test "classify_status: short when any rarity falls short" do
    assert ScoreCardList.classify_status(%{common: 0, uncommon: 0, rare: 3, mythic: 0}, %{
             common: 0,
             uncommon: 0,
             rare: 2,
             mythic: 0
           }) == :short
  end

  test "sort_key orders by mythic, rare, uncommon, common, then total" do
    assert ScoreCardList.sort_key(%{common: 1, uncommon: 0, rare: 0, mythic: 0}) ==
             {0, 0, 0, 1, 1}

    assert ScoreCardList.sort_key(%{common: 0, uncommon: 0, rare: 0, mythic: 1}) ==
             {1, 0, 0, 0, 1}
  end

  describe "score/4" do
    test "buildable when everything is owned (basics free)" do
      position =
        position(owned: %{1 => 4}, rarities: %{1 => "rare"}, free_arena_ids: MapSet.new([99]))

      main = [%{arena_id: 1, count: 4}, %{arena_id: 99, count: 12}]

      assert %Result{status: :buildable, maindeck: %Section{} = maindeck} =
               ScoreCardList.score(position, main, [], 0)

      assert maindeck.wildcard_cost == %{common: 0, uncommon: 0, rare: 0, mythic: 0}
      assert maindeck.owned_pct == 1.0
      assert maindeck.total_copies == 16
      assert maindeck.missing_copies == 0
    end

    test "craftable when wildcards on hand cover the cost" do
      position =
        position(
          owned: %{1 => 2},
          wildcards: %{common: 0, uncommon: 0, rare: 5, mythic: 0},
          rarities: %{1 => "rare"}
        )

      assert %Result{status: :craftable, maindeck: maindeck} =
               ScoreCardList.score(position, [%{arena_id: 1, count: 4}], [], 0)

      assert maindeck.wildcard_cost == %{common: 0, uncommon: 0, rare: 2, mythic: 0}
      assert maindeck.missing_copies == 2
    end

    test "short, with sort_key derived from the maindeck cost" do
      position = position(rarities: %{1 => "mythic"})

      assert %Result{status: :short, sort_key: {4, 0, 0, 0, 4}} =
               ScoreCardList.score(position, [%{arena_id: 1, count: 4}], [], 0)
    end

    test "incomplete when the list references cards missing from MTGA, even when the resolved cards are fully owned" do
      position = position(owned: %{1 => 4}, rarities: %{1 => "rare"})

      assert %Result{status: :incomplete} =
               ScoreCardList.score(position, [%{arena_id: 1, count: 4}], [], 15)
    end

    test "accepts card-list snapshots, not just entry lists" do
      position = position(owned: %{1 => 4}, rarities: %{1 => "rare"})

      assert %Result{status: :buildable} =
               ScoreCardList.score(
                 position,
                 %{"cards" => [%{"arena_id" => 1, "count" => 4}]},
                 nil,
                 0
               )
    end
  end

  describe "card_rows/3" do
    test "reports needed, owned and missing copies per card" do
      position = position(owned: %{1 => 1}, rarities: %{1 => "rare", 2 => "common"})
      cards = %{1 => %{name: "Sheoldred"}, 2 => %{name: "Shock"}}

      assert [sheoldred, shock] =
               ScoreCardList.card_rows(
                 position,
                 [%{arena_id: 1, count: 4}, %{arena_id: 2, count: 2}],
                 cards
               )

      assert %CardRow{
               arena_id: 1,
               name: "Sheoldred",
               rarity: "rare",
               needed: 4,
               owned: 1,
               missing: 3,
               free?: false
             } = sheoldred

      assert %CardRow{arena_id: 2, name: "Shock", needed: 2, owned: 0, missing: 2} = shock
    end

    test "free cards are never missing, whatever the collection says" do
      position = position(free_arena_ids: MapSet.new([99]))

      assert [%CardRow{missing: 0, free?: true}] =
               ScoreCardList.card_rows(position, [%{arena_id: 99, count: 20}], %{})
    end

    test "falls back to the arena_id when the card reference has no name" do
      assert [%CardRow{name: "#12345"}] =
               ScoreCardList.card_rows(position([]), [%{arena_id: 12_345, count: 1}], %{})
    end
  end
end
