defmodule Scry2.CardsTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.TestFactory

  describe "upsert_set!/1" do
    test "creates a new set" do
      set = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns of Ixalan"})

      assert set.code == "LCI"
      assert set.name == "Lost Caverns of Ixalan"
    end

    test "updates an existing set by code (idempotent)" do
      first = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns"})
      second = Cards.upsert_set!(%{code: "LCI", name: "Lost Caverns of Ixalan"})

      assert first.id == second.id
      assert second.name == "Lost Caverns of Ixalan"
    end
  end

  describe "upsert_card!/1" do
    test "creates a new card" do
      card =
        Cards.upsert_card!(%{
          lands17_id: 9001,
          arena_id: 91_001,
          name: "Test Card",
          rarity: "rare"
        })

      assert card.lands17_id == 9001
      assert card.arena_id == 91_001
    end

    test "updates an existing card by lands17_id (idempotent per ADR-016)" do
      first = Cards.upsert_card!(%{lands17_id: 9002, name: "Old Name"})
      second = Cards.upsert_card!(%{lands17_id: 9002, name: "New Name"})

      assert first.id == second.id
      assert second.name == "New Name"
    end

    test "never overwrites an existing arena_id (ADR-014 stable key invariant)" do
      _first = Cards.upsert_card!(%{lands17_id: 9003, arena_id: 91_003, name: "First"})

      # Second upsert omits arena_id — existing value must be preserved.
      second = Cards.upsert_card!(%{lands17_id: 9003, name: "Second"})

      assert second.arena_id == 91_003
    end
  end

  describe "get_by_arena_id/1 and get_by_lands17_id/1" do
    test "return nil for unknown ids" do
      assert Cards.get_by_arena_id(99_999_999) == nil
      assert Cards.get_by_lands17_id(99_999_999) == nil
    end

    test "return the card when found" do
      card = TestFactory.create_card(%{lands17_id: 9100, arena_id: 91_100})

      assert Cards.get_by_arena_id(91_100).id == card.id
      assert Cards.get_by_lands17_id(9100).id == card.id
    end
  end

  describe "list_cards/1" do
    setup do
      TestFactory.create_card(%{lands17_id: 9200, name: "Aardvark", rarity: "common"})
      TestFactory.create_card(%{lands17_id: 9201, name: "Zebra", rarity: "mythic"})
      :ok
    end

    test "returns all cards by default" do
      assert length(Cards.list_cards()) >= 2
    end

    test "filters by rarity" do
      mythics = Cards.list_cards(%{rarity: "mythic"})
      assert Enum.all?(mythics, &(&1.rarity == "mythic"))
    end

    test "filters by name substring" do
      results = Cards.list_cards(%{name_like: "ardv"})
      assert Enum.any?(results, &(&1.name == "Aardvark"))
    end
  end
end
