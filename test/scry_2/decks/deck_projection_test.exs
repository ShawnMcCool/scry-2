defmodule Scry2.Decks.DeckProjectionTest do
  use Scry2.DataCase

  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Decks.{DeckProjection, MatchResult}
  alias Scry2.Repo

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
end
