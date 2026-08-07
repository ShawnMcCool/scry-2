defmodule Scry2.BuildabilityTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory

  alias Scry2.Buildability
  alias Scry2.Buildability.Assessment

  defp card_list(entries),
    do: %{"cards" => Enum.map(entries, fn {id, n} -> %{"arena_id" => id, "count" => n} end)}

  defp cards_by_arena_id(cards) do
    Map.new(cards, fn card -> {card.arena_id, card} end)
  end

  describe "assess/4 without a collection snapshot" do
    test "reports the collection as unknown rather than claiming nothing is owned" do
      bolt = create_card(name: "Lightning Bolt", rarity: "rare")
      cards = cards_by_arena_id([bolt])

      assessment =
        Buildability.assess(card_list([{bolt.arena_id, 4}]), nil, cards)

      refute assessment.collection_known?
      assert [%{name: "Lightning Bolt", needed: 4, owned: 0, missing: 4}] = assessment.main_rows
    end
  end

  describe "assess/4 with a collection snapshot" do
    test "counts owned copies and prices the rest in wildcards" do
      bolt = create_card(name: "Lightning Bolt", rarity: "rare")
      opt = create_card(name: "Opt", rarity: "common")
      cards = cards_by_arena_id([bolt, opt])

      create_collection_snapshot(
        entries: [{bolt.arena_id, 1}, {opt.arena_id, 4}],
        wildcards_common: 9,
        wildcards_uncommon: 9,
        wildcards_rare: 9,
        wildcards_mythic: 9
      )

      assessment =
        Buildability.assess(
          card_list([{bolt.arena_id, 4}, {opt.arena_id, 4}]),
          nil,
          cards
        )

      assert assessment.collection_known?
      assert assessment.result.status == :craftable
      assert assessment.result.maindeck.wildcard_cost.rare == 3
      assert assessment.result.maindeck.missing_copies == 3
      assert assessment.wildcards == %{common: 9, uncommon: 9, rare: 9, mythic: 9}

      rows = Assessment.rows_by_arena_id(assessment)
      assert rows[bolt.arena_id].missing == 3
      assert rows[opt.arena_id].missing == 0
    end

    test "a fully owned list is buildable, with no missing copies" do
      opt = create_card(name: "Opt", rarity: "common")
      cards = cards_by_arena_id([opt])

      create_collection_snapshot(entries: [{opt.arena_id, 4}], wildcards_common: 0)

      assessment = Buildability.assess(card_list([{opt.arena_id, 4}]), nil, cards)

      assert assessment.result.status == :buildable
      assert Assessment.fully_owned?(assessment)
      assert Assessment.missing_copies(assessment) == 0
    end

    test "sideboard shortages count toward missing copies but not toward status" do
      opt = create_card(name: "Opt", rarity: "common")
      negate = create_card(name: "Negate", rarity: "uncommon")
      cards = cards_by_arena_id([opt, negate])

      create_collection_snapshot(entries: [{opt.arena_id, 4}], wildcards_uncommon: 0)

      assessment =
        Buildability.assess(
          card_list([{opt.arena_id, 4}]),
          card_list([{negate.arena_id, 2}]),
          cards
        )

      assert assessment.result.status == :buildable
      assert assessment.result.sideboard.wildcard_cost.uncommon == 2
      assert Assessment.missing_copies(assessment) == 2
      refute Assessment.fully_owned?(assessment)
    end

    test "ownership counts every printing of a card name, not just the one the list names" do
      original = create_card(name: "Duress", rarity: "common")
      reprint = create_card(name: "Duress", rarity: "common")
      cards = cards_by_arena_id([original])

      create_collection_snapshot(entries: [{reprint.arena_id, 4}])

      assessment = Buildability.assess(card_list([{original.arena_id, 4}]), nil, cards)

      assert [%{owned: 4, missing: 0}] = assessment.main_rows
    end

    test "basic lands are never missing" do
      mountain = create_card(name: "Mountain", rarity: "common")
      cards = cards_by_arena_id([mountain])

      create_collection_snapshot(entries: [])

      assessment = Buildability.assess(card_list([{mountain.arena_id, 24}]), nil, cards)

      assert [%{free?: true, missing: 0}] = assessment.main_rows
      assert assessment.result.status == :buildable
    end
  end

  describe "position/1 reuse" do
    test "a position read once scores several lists identically to assessing each" do
      bolt = create_card(name: "Lightning Bolt", rarity: "rare")
      cards = cards_by_arena_id([bolt])
      create_collection_snapshot(entries: [{bolt.arena_id, 2}])

      position = Buildability.position(cards)
      list = card_list([{bolt.arena_id, 4}])

      assert Buildability.score(position, list, nil) ==
               Buildability.assess(list, nil, cards).result
    end
  end
end
