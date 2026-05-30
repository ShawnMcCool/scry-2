defmodule Scry2.Decks.DeckProjectionTest do
  use Scry2.DataCase

  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Decks.{DeckProjection, MatchResult}
  alias Scry2.Repo

  alias Scry2.Decks.Deck

  describe "deck format inference from event_name" do
    test "backfills nil format from match event_name on DeckSubmitted" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # DeckUpdated with nil format (simulates filtered event-type format)
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Test Deck",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "Ladder",
          format: "ranked",
          format_type: "Constructed"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Standard"
    end

    test "does not overwrite existing format" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # DeckUpdated establishes format as "Historic"
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Test Deck",
          format: "Historic",
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "Ladder",
          format: "ranked",
          format_type: "Constructed"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Historic"
    end

    test "backfills Limited format on a DeckUpdated-sourced deck (draft queue)" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # User built and named the deck in MTGA — MTGA tags no format.
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "SoS Pick Two II 1.0",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "PickTwoDraft_SOS_20260421",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Pick Two Draft"
    end

    test "backfills plain \"Limited\" for a Direct Challenge limited deck" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "PickTwo I 1.0",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "DirectGameLimited",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Limited"
    end
  end

  describe "game_completed projection" do
    test "stores num_mulligans in game_results" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "WU"],
          games: [
            [won: true, on_play: true, num_mulligans: 2]
          ],
          won: nil
        )

      project_events(DeckProjection, scenario)

      assert [match_result] = Repo.all(MatchResult)
      results = match_result.game_results["results"]
      assert [game] = results
      assert game["num_mulligans"] == 2
    end

    test "defaults num_mulligans to 0 when event field is nil" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "WU"],
          games: [
            [won: true, on_play: true, num_mulligans: 0]
          ],
          won: nil
        )

      project_events(DeckProjection, scenario)

      assert [match_result] = Repo.all(MatchResult)
      results = match_result.game_results["results"]
      assert [game] = results
      assert game["num_mulligans"] == 0
    end
  end

  describe "deck_deleted projection" do
    test "sets archived=true on the matching deck" do
      player = create_player()
      deck_id = "deck-to-delete-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Goldfish Brew",
          format: "Standard",
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_deck_deleted(%{mtga_deck_id: deck_id})
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.archived == true
      assert deck.current_name == "Goldfish Brew"
    end

    test "is a no-op when the deck row does not exist (replay safety)" do
      events = [build_deck_deleted(%{mtga_deck_id: "unknown-deck"})]

      project_events(DeckProjection, events)

      refute Repo.get_by(Deck, mtga_deck_id: "unknown-deck")
    end
  end
end
