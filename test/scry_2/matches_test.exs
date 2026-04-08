defmodule Scry2.MatchesTest do
  use Scry2.DataCase

  alias Scry2.Matches
  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "upsert_match!/1" do
    test "inserts a new match and broadcasts" do
      Topics.subscribe(Topics.matches_updates())

      match =
        Matches.upsert_match!(%{
          mtga_match_id: "m-abc-123",
          event_name: "Traditional_Ladder",
          started_at: DateTime.utc_now(:second),
          opponent_screen_name: "Opponent1"
        })

      assert %Match{id: id, mtga_match_id: "m-abc-123"} = match
      assert_receive {:match_updated, ^id}
    end

    test "updates an existing match by mtga_match_id (idempotent)" do
      first = Matches.upsert_match!(%{mtga_match_id: "m-xyz", event_name: "A"})
      second = Matches.upsert_match!(%{mtga_match_id: "m-xyz", event_name: "B"})

      assert first.id == second.id
      assert second.event_name == "B"
      assert Matches.count() == 1
    end
  end

  describe "get_by_mtga_id/1" do
    test "returns the match with the given mtga_match_id" do
      match = TestFactory.create_match(%{mtga_match_id: "m-lookup-1"})
      assert Matches.get_by_mtga_id("m-lookup-1").id == match.id
    end

    test "returns nil when no match exists" do
      assert Matches.get_by_mtga_id("m-missing") == nil
    end
  end

  describe "upsert_game!/1" do
    setup do
      %{match: TestFactory.create_match()}
    end

    test "inserts a new game and broadcasts", %{match: match} do
      Topics.subscribe(Topics.matches_updates())

      game =
        Matches.upsert_game!(%{
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
      Matches.upsert_game!(%{match_id: match.id, game_number: 1, won: true, num_turns: 5})
      Matches.upsert_game!(%{match_id: match.id, game_number: 1, won: false, num_turns: 7})

      rows = Repo.all(Game)
      assert length(rows) == 1
      [game] = rows
      assert game.num_turns == 7
      assert game.won == false
    end

    test "distinct (match_id, game_number) pairs create separate rows", %{match: match} do
      Matches.upsert_game!(%{match_id: match.id, game_number: 1, won: true})
      Matches.upsert_game!(%{match_id: match.id, game_number: 2, won: false})

      assert length(Repo.all(Game)) == 2
    end
  end

  describe "upsert_deck_submission!/1" do
    test "inserts a new submission" do
      submission =
        Matches.upsert_deck_submission!(%{
          mtga_deck_id: "deck-abc",
          name: "Test Deck",
          main_deck: %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}
        })

      assert %DeckSubmission{mtga_deck_id: "deck-abc"} = submission
    end

    test "updates by mtga_deck_id" do
      main_deck = %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}

      first =
        Matches.upsert_deck_submission!(%{
          mtga_deck_id: "deck-xyz",
          name: "Old",
          main_deck: main_deck
        })

      second =
        Matches.upsert_deck_submission!(%{
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
        Matches.upsert_deck_submission!(%{
          mtga_deck_id: "deck-nomatch",
          name: "A",
          main_deck: main_deck
        })

      refute_received {:match_updated, _}

      _sub2 =
        Matches.upsert_deck_submission!(%{
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
      assert Matches.count() == 0
      TestFactory.create_match()
      TestFactory.create_match()
      assert Matches.count() == 2
    end
  end

  describe "aggregate_stats/1" do
    test "returns zeroed stats when no completed matches exist" do
      stats = Matches.aggregate_stats()
      assert stats.total == 0
      assert stats.wins == 0
      assert stats.losses == 0
      assert stats.win_rate == nil
      assert stats.by_format == []
      assert stats.by_deck_colors == []
    end

    test "computes overall win rate from completed matches" do
      TestFactory.create_match(%{won: true, format: "premier_draft", deck_colors: "UW"})
      TestFactory.create_match(%{won: true, format: "premier_draft", deck_colors: "UW"})
      TestFactory.create_match(%{won: false, format: "traditional_standard", deck_colors: "BR"})

      stats = Matches.aggregate_stats()

      assert stats.total == 3
      assert stats.wins == 2
      assert stats.losses == 1
      assert stats.win_rate == 66.7
    end

    test "breaks down by format" do
      TestFactory.create_match(%{won: true, format: "premier_draft"})
      TestFactory.create_match(%{won: false, format: "premier_draft"})
      TestFactory.create_match(%{won: true, format: "traditional_standard"})

      stats = Matches.aggregate_stats()

      draft = Enum.find(stats.by_format, &(&1.key == "premier_draft"))
      assert draft.total == 2
      assert draft.wins == 1
      assert draft.win_rate == 50.0

      standard = Enum.find(stats.by_format, &(&1.key == "traditional_standard"))
      assert standard.total == 1
      assert standard.wins == 1
      assert standard.win_rate == 100.0
    end

    test "breaks down by deck colors" do
      TestFactory.create_match(%{won: true, deck_colors: "UW"})
      TestFactory.create_match(%{won: false, deck_colors: "UW"})
      TestFactory.create_match(%{won: true, deck_colors: "BR"})

      stats = Matches.aggregate_stats()

      uw = Enum.find(stats.by_deck_colors, &(&1.key == "UW"))
      assert uw.total == 2
      assert uw.wins == 1

      br = Enum.find(stats.by_deck_colors, &(&1.key == "BR"))
      assert br.total == 1
      assert br.wins == 1
    end

    test "breaks down by deck name" do
      TestFactory.create_match(%{won: true, deck_name: "Mono Red Aggro"})
      TestFactory.create_match(%{won: false, deck_name: "Mono Red Aggro"})
      TestFactory.create_match(%{won: true, deck_name: "Azorius Control"})

      stats = Matches.aggregate_stats()

      mono_red = Enum.find(stats.by_deck_name, &(&1.key == "Mono Red Aggro"))
      assert mono_red.total == 2
      assert mono_red.wins == 1

      azorius = Enum.find(stats.by_deck_name, &(&1.key == "Azorius Control"))
      assert azorius.total == 1
      assert azorius.wins == 1
    end

    test "excludes matches where won is nil" do
      TestFactory.create_match(%{won: true})
      TestFactory.create_match(%{won: nil})

      stats = Matches.aggregate_stats()
      assert stats.total == 1
    end

    test "filters by player_id" do
      player = Scry2.Players.find_or_create!("player-1", "Player One")
      other = Scry2.Players.find_or_create!("player-2", "Player Two")

      TestFactory.create_match(%{won: true, player_id: player.id})
      TestFactory.create_match(%{won: false, player_id: other.id})

      stats = Matches.aggregate_stats(player_id: player.id)
      assert stats.total == 1
      assert stats.wins == 1
    end
  end

  describe "list_matches/1" do
    test "returns matches ordered by started_at desc" do
      older = TestFactory.create_match(%{started_at: ~U[2026-01-01 12:00:00Z]})
      newer = TestFactory.create_match(%{started_at: ~U[2026-04-01 12:00:00Z]})

      [first, second] = Matches.list_matches()
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "honors the :limit option" do
      for _ <- 1..3, do: TestFactory.create_match()
      assert length(Matches.list_matches(limit: 2)) == 2
    end
  end
end
