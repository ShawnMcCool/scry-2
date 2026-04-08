defmodule Scry2.MatchListing.UpdateFromEventTest do
  use Scry2.DataCase

  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Events
  alias Scry2.MatchListing
  alias Scry2.MatchListing.UpdateFromEvent

  describe "rebuild!/0" do
    test "match_created seeds a listing row" do
      player = create_player()

      scenario =
        match_scenario(player,
          event_name: "PremierDraft_LCI",
          opponent: "Rival",
          player_rank: "Platinum 2",
          format: "premier_draft",
          format_type: "limited",
          games: [],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      listing = MatchListing.get_by_mtga_id(scenario.match_id, player.id)
      assert listing
      assert listing.event_name == "PremierDraft_LCI"
      assert listing.opponent_screen_name == "Rival"
      assert listing.player_rank == "Platinum 2"
      assert listing.format == "premier_draft"
      assert listing.format_type == "limited"
    end

    test "match_created with nil player_id is skipped" do
      event = build_match_created(%{player_id: nil})
      project_events(UpdateFromEvent, event)

      listings = Scry2.Repo.all(Scry2.MatchListing.MatchListing)
      assert listings == []
    end

    test "match_completed writes won, num_games, duration" do
      player = create_player()
      started = ~U[2026-04-08 10:00:00Z]

      scenario =
        match_scenario(player,
          started_at: started,
          won: false,
          games: [
            [won: true, on_play: true],
            [won: false, on_play: false],
            [won: false, on_play: true]
          ]
        )

      project_events(UpdateFromEvent, scenario)

      listing = MatchListing.get_by_mtga_id(scenario.match_id, player.id)
      assert listing.won == false
      assert listing.num_games == 3
      assert listing.duration_seconds != nil
    end

    test "game_completed accumulates results and derives totals" do
      player = create_player()

      scenario =
        match_scenario(player,
          games: [
            [won: true, on_play: true, num_turns: 7, num_mulligans: 1],
            [won: false, on_play: false, num_turns: 12, num_mulligans: 0]
          ],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      listing = MatchListing.get_by_mtga_id(scenario.match_id, player.id)
      assert listing.on_play == true
      assert listing.total_mulligans == 1
      assert listing.total_turns == 19

      results = listing.game_results["results"]
      assert length(results) == 2
      assert Enum.at(results, 0)["game"] == 1
      assert Enum.at(results, 1)["game"] == 2
    end

    test "duplicate game_completed for same game_number replaces" do
      player = create_player()
      match_id = "test-listing-dup-#{System.unique_integer([:positive])}"

      events = [
        build_match_created(%{player_id: player.id, mtga_match_id: match_id}),
        build_game_completed(%{
          player_id: player.id,
          mtga_match_id: match_id,
          game_number: 1,
          won: true,
          num_turns: 7
        }),
        build_game_completed(%{
          player_id: player.id,
          mtga_match_id: match_id,
          game_number: 1,
          won: false,
          num_turns: 10
        })
      ]

      project_events(UpdateFromEvent, events)

      listing = MatchListing.get_by_mtga_id(match_id, player.id)
      results = listing.game_results["results"]
      assert length(results) == 1
      assert Enum.at(results, 0)["won"] == false
      assert Enum.at(results, 0)["turns"] == 10
    end

    test "deck_submitted writes deck_colors" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "WUB"],
          games: [],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      listing = MatchListing.get_by_mtga_id(scenario.match_id, player.id)
      assert listing.deck_colors == "WUB"
    end

    test "full lifecycle produces correct denormalized listing" do
      player = create_player()
      started = ~U[2026-04-08 10:00:00Z]

      scenario =
        match_scenario(player,
          started_at: started,
          event_name: "PremierDraft_FDN",
          player_rank: "Gold 1",
          format: "premier_draft",
          format_type: "limited",
          deck: [colors: "RG"],
          won: true,
          games: [
            [won: true, on_play: true, num_turns: 8, num_mulligans: 0],
            [won: true, on_play: false, num_turns: 6, num_mulligans: 1]
          ]
        )

      project_events(UpdateFromEvent, scenario)

      listing = MatchListing.get_by_mtga_id(scenario.match_id, player.id)
      assert listing.event_name == "PremierDraft_FDN"
      assert listing.won == true
      assert listing.num_games == 2
      assert listing.on_play == true
      assert listing.total_mulligans == 1
      assert listing.total_turns == 14
      assert listing.deck_colors == "RG"
      assert listing.player_rank == "Gold 1"
    end

    test "watermark advances to last processed event" do
      player = create_player()

      scenario = match_scenario(player, games: [], won: nil)
      records = project_events(UpdateFromEvent, scenario)

      assert Events.get_watermark("MatchListing.UpdateFromEvent") == List.last(records).id
    end
  end
end
