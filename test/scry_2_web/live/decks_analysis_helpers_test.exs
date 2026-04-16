defmodule Scry2Web.DecksAnalysisHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DecksAnalysisHelpers, as: AH

  describe "sort_cards/4" do
    test "groups land cards under Lands" do
      card = %{card_arena_id: 100_652, card_name: "Forest", copies: 0, iwd: nil}
      cards_by_arena_id = %{100_652 => %{types: "Basic Land"}}

      groups = AH.sort_cards([card], cards_by_arena_id, nil, :type)
      labels = Enum.map(groups, &elem(&1, 0))

      assert "Lands" in labels
      refute "Unknown" in labels
    end

    test "groups a card under Unknown when arena_id is absent from cards_by_arena_id" do
      card = %{card_arena_id: 99999, card_name: "Some Card", copies: 0, iwd: nil}

      groups = AH.sort_cards([card], %{}, nil, :type)
      labels = Enum.map(groups, &elem(&1, 0))

      assert "Unknown" in labels
    end
  end

  describe "arena_ids_for_page/3" do
    test "includes arena_ids from card_performance not present in deck" do
      deck = %{current_main_deck: %{"cards" => []}, current_sideboard: nil}
      card_performance = [%{card_arena_id: 100_652}]

      arena_ids = AH.arena_ids_for_page(deck, [], card_performance)

      assert 100_652 in arena_ids
    end

    test "includes arena_ids from current deck" do
      deck = %{
        current_main_deck: %{"cards" => [%{"arena_id" => 12345}]},
        current_sideboard: nil
      }

      arena_ids = AH.arena_ids_for_page(deck, [], [])

      assert 12345 in arena_ids
    end

    test "includes arena_ids from deck versions" do
      version = %{
        main_deck_added: %{"cards" => [%{"arena_id" => 67890}]},
        main_deck_removed: nil,
        sideboard_added: nil,
        sideboard_removed: nil,
        main_deck: nil,
        sideboard: nil
      }

      arena_ids =
        AH.arena_ids_for_page(%{current_main_deck: nil, current_sideboard: nil}, [version], [])

      assert 67890 in arena_ids
    end

    test "deduplicates arena_ids across all sources" do
      deck = %{
        current_main_deck: %{"cards" => [%{"arena_id" => 100_652}]},
        current_sideboard: nil
      }

      card_performance = [%{card_arena_id: 100_652}]

      arena_ids = AH.arena_ids_for_page(deck, [], card_performance)

      assert Enum.count(arena_ids, &(&1 == 100_652)) == 1
    end

    test "filters out non-integer arena_ids" do
      deck = %{current_main_deck: %{"cards" => [%{"arena_id" => nil}]}, current_sideboard: nil}
      card_performance = [%{card_arena_id: "not-an-int"}]

      arena_ids = AH.arena_ids_for_page(deck, [], card_performance)

      assert arena_ids == []
    end
  end
end
