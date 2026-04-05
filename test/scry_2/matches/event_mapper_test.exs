defmodule Scry2.Matches.EventMapperTest do
  use ExUnit.Case, async: true

  alias Scry2.Matches.EventMapper
  alias Scry2.MtgaLogs.{Event, EventParser, EventRecord}

  # The self_user_id from the real Player.log used to capture fixtures.
  @self_user_id "D0FECB2AF1E7FE24"

  defp record_from_fixture(name) do
    chunk =
      File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))

    [%Event{} = event] = EventParser.parse_chunk(chunk, "Player.log", 0)

    %EventRecord{
      id: 1,
      event_type: event.type,
      mtga_timestamp: event.mtga_timestamp,
      file_offset: event.file_offset,
      source_file: event.source_file,
      raw_json: event.raw_json,
      processed: false
    }
  end

  describe "match_attrs_from_game_room_state_changed/2 — state=Playing" do
    test "extracts mtga_match_id, event_name, opponent, and started_at" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert {:ok, attrs} =
               EventMapper.match_attrs_from_game_room_state_changed(record, @self_user_id)

      assert attrs.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert attrs.event_name == "Traditional_Ladder"
      assert attrs.opponent_screen_name == "Opponent1"
      assert attrs.started_at == ~U[2026-04-05 19:18:40Z]
    end

    test "falls back to systemSeatId != 1 for opponent when self_user_id is nil" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert {:ok, attrs} =
               EventMapper.match_attrs_from_game_room_state_changed(record, nil)

      # The fixture has the user as seat 1 → opponent is seat 2 = "Opponent1"
      assert attrs.opponent_screen_name == "Opponent1"
      assert attrs.event_name == "Traditional_Ladder"
    end
  end

  describe "match_attrs_from_game_room_state_changed/2 — state=MatchCompleted" do
    test "returns :ignore (finalization is future work)" do
      record = record_from_fixture("match_game_room_state_changed_completed.log")

      assert :ignore =
               EventMapper.match_attrs_from_game_room_state_changed(record, @self_user_id)
    end
  end

  describe "match_attrs_from_game_room_state_changed/2 — defensive" do
    test "returns :ignore for an unrelated event type" do
      record = %EventRecord{
        id: 1,
        event_type: "EventJoin",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"2c568a83","request":"..."}),
        processed: false
      }

      assert :ignore =
               EventMapper.match_attrs_from_game_room_state_changed(record, @self_user_id)
    end

    test "returns :ignore on malformed JSON" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "not json at all",
        processed: false
      }

      assert :ignore =
               EventMapper.match_attrs_from_game_room_state_changed(record, @self_user_id)
    end

    test "returns :ignore when matchId is missing" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          ~s({"matchGameRoomStateChangedEvent":{"gameRoomInfo":{"gameRoomConfig":{"reservedPlayers":[]},"stateType":"MatchGameRoomStateType_Playing"}}}),
        processed: false
      }

      assert :ignore =
               EventMapper.match_attrs_from_game_room_state_changed(record, @self_user_id)
    end
  end
end
