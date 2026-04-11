defmodule Scry2.Events.IngestionStateInspectTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.{Match, Session}

  describe "project/1" do
    test "returns a friendly map for the diagnostics panel" do
      state = %IngestionState{
        last_raw_event_id: 42,
        session: %Session{
          self_user_id: "user-abc",
          player_id: 7,
          current_session_id: "sess-1",
          constructed_rank: "Gold 2",
          limited_rank: "Silver 4"
        },
        match: %Match{
          current_match_id: "m-1",
          current_game_number: 2,
          last_deck_name: "Dimir Midrange",
          on_play_for_current_game: true,
          pending_deck: nil
        }
      }

      projection = IngestionState.project(state)

      assert projection.last_raw_event_id == 42
      assert projection.session.self_user_id == "user-abc"
      assert projection.session.player_id == 7
      assert projection.session.current_session_id == "sess-1"
      assert projection.session.constructed_rank == "Gold 2"
      assert projection.session.limited_rank == "Silver 4"
      assert projection.match.current_match_id == "m-1"
      assert projection.match.current_game_number == 2
      assert projection.match.last_deck_name == "Dimir Midrange"
      assert projection.match.on_play_for_current_game == true
      assert projection.match.pending_deck? == false
    end

    test "reports pending_deck? as true when a deck is staged" do
      state = %IngestionState{
        match: %Match{pending_deck: %{something: "here"}}
      }

      assert IngestionState.project(state).match.pending_deck? == true
    end

    test "handles a fresh state gracefully" do
      projection = IngestionState.project(%IngestionState{})

      assert projection.last_raw_event_id == 0
      assert projection.session.self_user_id == nil
      assert projection.match.current_match_id == nil
      assert projection.match.pending_deck? == false
    end
  end
end
