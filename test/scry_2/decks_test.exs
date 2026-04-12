defmodule Scry2.DecksTest do
  use Scry2.DataCase

  alias Scry2.Decks
  alias Scry2.Decks.{Deck, GameSubmission, MatchResult}
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "upsert_deck!/1" do
    test "inserts a new deck and broadcasts" do
      Topics.subscribe(Topics.decks_updates())

      deck =
        Decks.upsert_deck!(%{mtga_deck_id: "d-abc", current_name: "My Deck", format: "Standard"})

      assert %Deck{mtga_deck_id: "d-abc", current_name: "My Deck"} = deck
      assert_receive {:deck_updated, "d-abc"}
    end

    test "updates an existing deck by mtga_deck_id (idempotent)" do
      first = Decks.upsert_deck!(%{mtga_deck_id: "d-xyz", current_name: "Old Name"})
      second = Decks.upsert_deck!(%{mtga_deck_id: "d-xyz", current_name: "New Name"})

      assert first.id == second.id
      assert second.current_name == "New Name"
      assert Scry2.Repo.aggregate(Deck, :count) == 1
    end
  end

  describe "get_deck/1" do
    test "returns the deck with the given mtga_deck_id" do
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-lookup"})
      assert Decks.get_deck("d-lookup").id == deck.id
    end

    test "returns nil when deck does not exist" do
      assert Decks.get_deck("d-missing") == nil
    end
  end

  describe "upsert_match_result!/1" do
    test "inserts a new match result and broadcasts" do
      Topics.subscribe(Topics.decks_updates())

      deck = TestFactory.create_deck()

      result =
        Decks.upsert_match_result!(%{
          mtga_deck_id: deck.mtga_deck_id,
          mtga_match_id: "m-001",
          won: true,
          format_type: "Standard"
        })

      assert %MatchResult{won: true} = result
      assert_receive {:deck_updated, _}
    end

    test "updates existing result by (mtga_deck_id, mtga_match_id) (idempotent)" do
      deck = TestFactory.create_deck()
      attrs = %{mtga_deck_id: deck.mtga_deck_id, mtga_match_id: "m-idem"}

      first = Decks.upsert_match_result!(Map.put(attrs, :won, nil))
      second = Decks.upsert_match_result!(Map.put(attrs, :won, true))

      assert first.id == second.id
      assert second.won == true
      assert Scry2.Repo.aggregate(MatchResult, :count) == 1
    end
  end

  describe "upsert_game_submission!/1" do
    test "inserts a game submission (idempotent by deck/match/game)" do
      deck = TestFactory.create_deck()

      attrs = %{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-gs-001",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => []}
      }

      first = Decks.upsert_game_submission!(attrs)
      second = Decks.upsert_game_submission!(Map.put(attrs, :game_number, 1))

      assert first.id == second.id
      assert Scry2.Repo.aggregate(GameSubmission, :count) == 1
    end

    test "stores separate submissions for different game numbers" do
      deck = TestFactory.create_deck()
      base = %{mtga_deck_id: deck.mtga_deck_id, mtga_match_id: "m-multi"}

      Decks.upsert_game_submission!(Map.put(base, :game_number, 1))
      Decks.upsert_game_submission!(Map.put(base, :game_number, 2))

      assert Scry2.Repo.aggregate(GameSubmission, :count) == 2
    end
  end

  describe "list_decks_with_stats/0" do
    test "returns only decks with at least one completed match" do
      deck_with_match = TestFactory.create_deck(%{mtga_deck_id: "d-played"})
      _deck_no_match = TestFactory.create_deck(%{mtga_deck_id: "d-unplayed"})

      TestFactory.create_deck_match_result(%{deck: deck_with_match, won: true})

      result = Decks.list_decks_with_stats()
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      assert "d-played" in deck_ids
      refute "d-unplayed" in deck_ids
    end

    test "aggregates BO1 and BO3 stats separately" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: false})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      [entry] = Decks.list_decks_with_stats()

      assert entry.bo1.total == 2
      assert entry.bo1.wins == 1
      assert entry.bo1.win_rate == 50.0
      assert entry.bo3.total == 1
      assert entry.bo3.wins == 1
      assert entry.bo3.win_rate == 100.0
    end
  end

  describe "get_deck_performance/1" do
    test "returns zero stats for a deck with no completed matches" do
      deck = TestFactory.create_deck()
      perf = Decks.get_deck_performance(deck.mtga_deck_id)

      assert perf.bo1.total == 0
      assert perf.bo3.total == 0
      assert perf.cumulative_win_rate == %{bo1: [], bo3: []}
    end

    test "separates BO1 and BO3 results" do
      deck = TestFactory.create_deck()
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: false})

      perf = Decks.get_deck_performance(deck.mtga_deck_id)

      assert perf.bo1.total == 1
      assert perf.bo1.wins == 1
      assert perf.bo3.total == 1
      assert perf.bo3.losses == 1
    end
  end

  describe "get_deck_sideboard_diff/1" do
    test "returns diffs only for matches with multiple game submissions" do
      deck = TestFactory.create_deck()

      # Two games — should produce a diff
      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo3",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => [%{"arena_id" => 100, "count" => 2}]}
      })

      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo3",
        game_number: 2,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => [%{"arena_id" => 200, "count" => 1}]}
      })

      # Single game — should be excluded
      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo1",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => []}
      })

      diffs = Decks.get_deck_sideboard_diff(deck.mtga_deck_id)

      assert length(diffs) == 1
      [diff] = diffs
      assert diff.mtga_match_id == "m-bo3"
      assert Enum.any?(diff.changes.added, &(&1.arena_id == 200))
      assert Enum.any?(diff.changes.removed, &(&1.arena_id == 100))
    end
  end
end
