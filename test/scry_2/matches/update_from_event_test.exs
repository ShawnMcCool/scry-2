defmodule Scry2.Matches.UpdateFromEventTest do
  use Scry2.DataCase

  import ExUnit.CaptureLog
  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Events
  alias Scry2.Matches
  alias Scry2.Matches.UpdateFromEvent

  describe "rebuild!/0" do
    test "match_created projects a match row" do
      player = create_player()

      scenario =
        match_scenario(player,
          event_name: "Traditional_Ladder",
          opponent: "OpponentA",
          games: [],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      match = Matches.get_by_mtga_id(scenario.match_id, player.id)
      assert match
      assert match.event_name == "Traditional_Ladder"
      assert match.opponent_screen_name == "OpponentA"
    end

    test "match_completed enriches an existing match" do
      player = create_player()
      started = ~U[2026-04-08 10:00:00Z]

      scenario =
        match_scenario(player,
          started_at: started,
          won: true,
          games: [
            [won: true, on_play: true],
            [won: false, on_play: false]
          ]
        )

      project_events(UpdateFromEvent, scenario)

      match = Matches.get_by_mtga_id(scenario.match_id, player.id)
      assert match.won == true
      assert match.num_games == 2
      assert match.ended_at != nil
    end

    test "game_completed creates a game linked to the match" do
      player = create_player()

      scenario =
        match_scenario(player,
          games: [[won: true, on_play: true, num_turns: 8]],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      match = Matches.get_by_mtga_id(scenario.match_id, player.id)
      games = Scry2.Repo.all(Scry2.Matches.Game)
      game = Enum.find(games, &(&1.match_id == match.id))
      assert game
      assert game.game_number == 1
      assert game.on_play == true
      assert game.num_turns == 8
    end

    test "game_completed for unknown match logs warning" do
      player = create_player()

      event = build_game_completed(%{player_id: player.id, mtga_match_id: "nonexistent-match"})

      log = capture_log(fn -> project_events(UpdateFromEvent, event) end)
      assert log =~ "unknown match"
    end

    test "deck_submitted creates a deck submission" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "BRG"],
          games: [],
          won: nil
        )

      project_events(UpdateFromEvent, scenario)

      submissions = Scry2.Repo.all(Scry2.Matches.DeckSubmission)
      assert length(submissions) == 1
      assert hd(submissions).match_id != nil
    end

    test "full lifecycle produces correct match state" do
      player = create_player()

      scenario =
        match_scenario(player,
          event_name: "PremierDraft_FDN",
          won: true,
          games: [
            [won: true, on_play: true, num_turns: 7],
            [won: false, on_play: false, num_turns: 11]
          ]
        )

      project_events(UpdateFromEvent, scenario)

      match = Matches.get_by_mtga_id(scenario.match_id, player.id)
      assert match.won == true
      assert match.num_games == 2

      games =
        Scry2.Repo.all(Scry2.Matches.Game) |> Enum.filter(&(&1.match_id == match.id))

      assert length(games) == 2
    end

    test "watermark advances to last processed event" do
      player = create_player()

      scenario = match_scenario(player, games: [], won: nil)
      records = project_events(UpdateFromEvent, scenario)

      watermark = Events.get_watermark("Matches.UpdateFromEvent")
      assert watermark == List.last(records).id
    end

    test "idempotent replay produces same state" do
      player = create_player()

      scenario = match_scenario(player, games: [], won: nil)

      project_events(UpdateFromEvent, scenario)
      # Rebuild again — should produce same result
      UpdateFromEvent.rebuild!()

      matches =
        Scry2.Repo.all(Scry2.Matches.Match)
        |> Enum.filter(&(&1.mtga_match_id == scenario.match_id))

      assert length(matches) == 1
    end
  end
end
