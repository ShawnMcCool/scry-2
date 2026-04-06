defmodule Scry2.MatchListingTest do
  use Scry2.DataCase

  alias Scry2.MatchListing
  alias Scry2.MatchListing.{DeckSubmission, Game, Match}
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "upsert_match!/1" do
    test "inserts a new match and broadcasts" do
      Topics.subscribe(Topics.matches_updates())

      match =
        MatchListing.upsert_match!(%{
          mtga_match_id: "m-abc-123",
          event_name: "Traditional_Ladder",
          started_at: DateTime.utc_now(:second),
          opponent_screen_name: "Opponent1"
        })

      assert %Match{id: id, mtga_match_id: "m-abc-123"} = match
      assert_receive {:match_updated, ^id}
    end

    test "updates an existing match by mtga_match_id (idempotent)" do
      first = MatchListing.upsert_match!(%{mtga_match_id: "m-xyz", event_name: "A"})
      second = MatchListing.upsert_match!(%{mtga_match_id: "m-xyz", event_name: "B"})

      assert first.id == second.id
      assert second.event_name == "B"
      assert MatchListing.count() == 1
    end
  end

  describe "get_by_mtga_id/1" do
    test "returns the match with the given mtga_match_id" do
      match = TestFactory.create_match(%{mtga_match_id: "m-lookup-1"})
      assert MatchListing.get_by_mtga_id("m-lookup-1").id == match.id
    end

    test "returns nil when no match exists" do
      assert MatchListing.get_by_mtga_id("m-missing") == nil
    end
  end

  describe "upsert_game!/1" do
    setup do
      %{match: TestFactory.create_match()}
    end

    test "inserts a new game and broadcasts", %{match: match} do
      Topics.subscribe(Topics.matches_updates())

      game =
        MatchListing.upsert_game!(%{
          match_id: match.id,
          game_number: 1,
          on_play: true,
          won: true,
          num_turns: 9
        })

      assert %Game{match_id: mid, game_number: 1} = game
      assert mid == match.id
      assert_receive {:match_updated, ^mid}
    end

    test "updates existing game by (match_id, game_number)", %{match: match} do
      MatchListing.upsert_game!(%{match_id: match.id, game_number: 1, won: true, num_turns: 5})
      MatchListing.upsert_game!(%{match_id: match.id, game_number: 1, won: false, num_turns: 7})

      rows = Repo.all(Game)
      assert length(rows) == 1
      [game] = rows
      assert game.num_turns == 7
      assert game.won == false
    end

    test "distinct (match_id, game_number) pairs create separate rows", %{match: match} do
      MatchListing.upsert_game!(%{match_id: match.id, game_number: 1, won: true})
      MatchListing.upsert_game!(%{match_id: match.id, game_number: 2, won: false})

      assert length(Repo.all(Game)) == 2
    end
  end

  describe "upsert_deck_submission!/1" do
    test "inserts a new submission" do
      submission =
        MatchListing.upsert_deck_submission!(%{
          mtga_deck_id: "deck-abc",
          name: "Test Deck",
          main_deck: %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}
        })

      assert %DeckSubmission{mtga_deck_id: "deck-abc"} = submission
    end

    test "updates by mtga_deck_id" do
      main_deck = %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}

      first =
        MatchListing.upsert_deck_submission!(%{
          mtga_deck_id: "deck-xyz",
          name: "Old",
          main_deck: main_deck
        })

      second =
        MatchListing.upsert_deck_submission!(%{
          mtga_deck_id: "deck-xyz",
          name: "New",
          main_deck: main_deck
        })

      assert first.id == second.id
      assert second.name == "New"
    end

    test "broadcasts only when match_id is present" do
      match = TestFactory.create_match()
      main_deck = %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}

      # Subscribe AFTER create_match so we don't see the factory's own broadcast.
      Topics.subscribe(Topics.matches_updates())

      _sub1 =
        MatchListing.upsert_deck_submission!(%{
          mtga_deck_id: "deck-nomatch",
          name: "A",
          main_deck: main_deck
        })

      refute_received {:match_updated, _}

      _sub2 =
        MatchListing.upsert_deck_submission!(%{
          mtga_deck_id: "deck-withmatch",
          name: "B",
          main_deck: main_deck,
          match_id: match.id
        })

      assert_receive {:match_updated, match_id}
      assert match_id == match.id
    end
  end

  describe "count/0" do
    test "returns the number of matches" do
      assert MatchListing.count() == 0
      TestFactory.create_match()
      TestFactory.create_match()
      assert MatchListing.count() == 2
    end
  end

  describe "list_matches/1" do
    test "returns matches ordered by started_at desc" do
      older = TestFactory.create_match(%{started_at: ~U[2026-01-01 12:00:00Z]})
      newer = TestFactory.create_match(%{started_at: ~U[2026-04-01 12:00:00Z]})

      [first, second] = MatchListing.list_matches()
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "honors the :limit option" do
      for _ <- 1..3, do: TestFactory.create_match()
      assert length(MatchListing.list_matches(limit: 2)) == 2
    end
  end
end
