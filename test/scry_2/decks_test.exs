defmodule Scry2.DecksTest do
  use Scry2.DataCase

  alias Scry2.Cards
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

  describe "list_matches_for_deck/2" do
    test "returns all completed matches and total count with no opts" do
      deck = TestFactory.create_deck()
      TestFactory.create_deck_match_result(%{deck: deck, won: true})
      TestFactory.create_deck_match_result(%{deck: deck, won: false})

      {matches, total} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert total == 2
      assert length(matches) == 2
    end

    test "paginates with limit and offset" do
      deck = TestFactory.create_deck()

      for i <- 1..3 do
        Decks.upsert_match_result!(%{
          mtga_deck_id: deck.mtga_deck_id,
          mtga_match_id: "m-pag-#{i}",
          won: true,
          format_type: "Standard",
          started_at: DateTime.add(DateTime.utc_now(:second), -i, :second)
        })
      end

      {page1, total} = Decks.list_matches_for_deck(deck.mtga_deck_id, limit: 2, offset: 0)
      assert total == 3
      assert length(page1) == 2

      {page2, _} = Decks.list_matches_for_deck(deck.mtga_deck_id, limit: 2, offset: 2)
      assert length(page2) == 1
    end

    test "filters to BO3 matches only with format: :bo3" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})

      {bo3_matches, bo3_total} = Decks.list_matches_for_deck(deck.mtga_deck_id, format: :bo3)

      assert bo3_total == 1
      assert length(bo3_matches) == 1
      assert hd(bo3_matches).format_type == "Traditional"
    end

    test "filters to BO1 matches only with format: :bo1" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      {bo1_matches, bo1_total} = Decks.list_matches_for_deck(deck.mtga_deck_id, format: :bo1)

      assert bo1_total == 1
      assert length(bo1_matches) == 1
      assert hd(bo1_matches).format_type == "Standard"
    end

    test "excludes incomplete matches (won is nil)" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, won: true})

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-incomplete",
        won: nil
      })

      {matches, total} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert total == 1
      assert length(matches) == 1
    end

    test "returns results newest first" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-older",
        won: true,
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-newer",
        won: true,
        started_at: now
      })

      {matches, _} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert hd(matches).mtga_match_id == "m-newer"
    end
  end

  describe "latest_format/1" do
    test "returns :bo3 when no matches exist" do
      deck = TestFactory.create_deck()

      assert Decks.latest_format(deck.mtga_deck_id) == :bo3
    end

    test "returns :bo3 when most recent match is Traditional" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-standard",
        won: true,
        format_type: "Standard",
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-trad",
        won: true,
        format_type: "Traditional",
        started_at: now
      })

      assert Decks.latest_format(deck.mtga_deck_id) == :bo3
    end

    test "returns :bo1 when most recent match is Standard" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-trad",
        won: true,
        format_type: "Traditional",
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-standard",
        won: true,
        format_type: "Standard",
        started_at: now
      })

      assert Decks.latest_format(deck.mtga_deck_id) == :bo1
    end
  end

  describe "match_counts_by_format/1" do
    test "returns zero counts for a deck with no matches" do
      deck = TestFactory.create_deck()

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 0, bo3: 0}
    end

    test "counts BO1 and BO3 matches separately" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: false})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 2, bo3: 1}
    end

    test "excludes incomplete matches from counts" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-incomplete",
        won: nil,
        format_type: "Standard"
      })

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 1, bo3: 0}
    end
  end

  describe "card_performance/1" do
    test "excludes opponent draws (is_self_draw: false)" do
      deck = TestFactory.create_deck()
      match_id = "m-opponent-#{System.unique_integer([:positive])}"
      opponent_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{arena_id: opponent_arena_id, name: "Opponent Spell", rarity: 3})

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: opponent_arena_id,
        match_won: true,
        is_self_draw: false,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute opponent_arena_id in result_ids
    end

    test "excludes token cards (is_token: true in MtgaCard)" do
      deck = TestFactory.create_deck()
      match_id = "m-token-#{System.unique_integer([:positive])}"
      token_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{
        arena_id: token_arena_id,
        name: "Treasure",
        is_token: true,
        rarity: 0
      })

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: token_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute token_arena_id in result_ids
    end

    test "excludes arena_ids with no card table entry (nil card_name)" do
      deck = TestFactory.create_deck()
      match_id = "m-unknown-#{System.unique_integer([:positive])}"
      unknown_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: unknown_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute unknown_arena_id in result_ids
    end

    test "includes self draws of known non-token cards" do
      deck = TestFactory.create_deck()
      match_id = "m-self-#{System.unique_integer([:positive])}"
      card_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{arena_id: card_arena_id, name: "Lightning Bolt", rarity: 2})

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: card_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      assert card_arena_id in result_ids
    end
  end
end
