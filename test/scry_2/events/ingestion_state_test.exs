defmodule Scry2.Events.IngestionStateTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.{Match, Session}
  alias Scry2.TestFactory

  describe "new/1" do
    test "returns fresh state" do
      state = IngestionState.new()
      assert state.version == 1
      assert state.last_raw_event_id == 0
      assert state.session == %Session{}
      assert state.match == %Match{}
    end

    test "seeds self_user_id" do
      state = IngestionState.new(self_user_id: "abc")
      assert state.session.self_user_id == "abc"
    end
  end

  describe "advance/2" do
    test "updates last_raw_event_id" do
      state = IngestionState.new() |> IngestionState.advance(42)
      assert state.last_raw_event_id == 42
    end
  end

  describe "apply_event — session scope" do
    test "SessionStarted sets self_user_id and session_id" do
      event =
        TestFactory.build_session_started(%{
          client_id: "user-abc",
          session_id: "sess-1"
        })

      {state, side_effects} = IngestionState.apply_event(IngestionState.new(), event)

      assert state.session.self_user_id == "user-abc"
      assert state.session.current_session_id == "sess-1"
      assert state.session.player_id == nil
      assert side_effects == []
    end
  end

  describe "apply_event — match scope" do
    test "MatchCreated sets current_match_id" do
      event = TestFactory.build_match_created(%{mtga_match_id: "match-1"})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.current_match_id == "match-1"
    end

    test "MatchCreated emits pending_deck as side effect" do
      pending =
        TestFactory.build_deck_submitted(%{
          mtga_match_id: nil,
          mtga_deck_id: "pending:seat1",
          main_deck: [],
          sideboard: []
        })

      state = %{IngestionState.new() | match: %Match{pending_deck: pending}}
      event = TestFactory.build_match_created(%{mtga_match_id: "match-1"})
      {new_state, [deck]} = IngestionState.apply_event(state, event)

      assert deck.mtga_match_id == "match-1"
      assert deck.mtga_deck_id == "match-1:seat1"
      assert new_state.match.pending_deck == nil
    end

    test "DeckSelected sets last_deck_name" do
      event = TestFactory.build_deck_selected(%{deck_name: "My Green Deck"})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.last_deck_name == "My Green Deck"
    end

    test "DieRolled sets on_play_for_current_game" do
      event = TestFactory.build_die_rolled(%{self_goes_first: true})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.on_play_for_current_game == true
    end

    test "StartingPlayerChosen sets on_play_for_current_game" do
      event = TestFactory.build_starting_player_chosen(%{chose_play: false})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.on_play_for_current_game == false
    end

    test "DeckSubmitted with match_id increments game number" do
      event = TestFactory.build_deck_submitted(%{mtga_match_id: "match-1"})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.current_game_number == 1
    end

    test "DeckSubmitted with nil match_id caches as pending" do
      event = TestFactory.build_deck_submitted(%{mtga_match_id: nil})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.pending_deck == event
    end

    test "MatchCompleted resets match scope" do
      state = %{
        IngestionState.new()
        | match: %Match{current_match_id: "m-1", current_game_number: 2}
      }

      event = TestFactory.build_match_completed()
      {new_state, []} = IngestionState.apply_event(state, event)

      assert new_state.match == %Match{}
      assert new_state.session == state.session
    end

    test "unknown event is a no-op" do
      {state, []} = IngestionState.apply_event(IngestionState.new(), :whatever)
      assert state == IngestionState.new()
    end
  end

  describe "serialization round-trip" do
    test "from_map/1 restores a serialized state" do
      original = %IngestionState{
        version: 1,
        last_raw_event_id: 42,
        session: %Session{self_user_id: "user-1", player_id: 3, constructed_rank: "Gold 1"},
        match: %Match{current_match_id: "m-abc", current_game_number: 2}
      }

      json = Jason.encode!(original)
      restored = IngestionState.from_map(Jason.decode!(json))

      assert restored.version == 1
      assert restored.last_raw_event_id == 42
      assert restored.session.self_user_id == "user-1"
      assert restored.session.player_id == 3
      assert restored.match.current_match_id == "m-abc"
      assert restored.match.current_game_number == 2
    end

    test "from_map/1 with nil returns fresh state" do
      assert IngestionState.from_map(nil) == IngestionState.new()
    end
  end
end
