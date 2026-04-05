defmodule Scry2.Events.TranslatorTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.{MatchCompleted, MatchCreated, Translator}
  alias Scry2.MtgaLogs.{Event, EventParser, EventRecord}

  # The self_user_id baked into the captured fixtures.
  @self_user_id "D0FECB2AF1E7FE24"

  # Reads a real fixture and returns a synthetic %EventRecord{} with the
  # fixture's raw JSON and parsed timestamp. Pure setup — no DB.
  defp record_from_fixture(fixture_name) do
    path = Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", fixture_name])
    chunk = File.read!(path)
    [%Event{} = event] = EventParser.parse_chunk(chunk, "Player.log", 0)

    %EventRecord{
      id: 1,
      event_type: event.type,
      mtga_timestamp: event.mtga_timestamp,
      file_offset: 0,
      source_file: "Player.log",
      raw_json: event.raw_json,
      processed: false
    }
  end

  describe "translate/2 — MatchGameRoomStateChangedEvent, stateType=Playing" do
    test "produces a single %MatchCreated{} with the expected fields" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert [%MatchCreated{} = event] = Translator.translate(record, @self_user_id)
      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.event_name == "Traditional_Ladder"
      assert event.opponent_screen_name == "Opponent1"
      assert event.started_at == ~U[2026-04-05 19:18:40Z]
    end

    test "falls back to systemSeatId != 1 for opponent when self_user_id is nil" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert [%MatchCreated{} = event] = Translator.translate(record, nil)
      assert event.opponent_screen_name == "Opponent1"
      assert event.event_name == "Traditional_Ladder"
    end
  end

  describe "translate/2 — MatchGameRoomStateChangedEvent, stateType=MatchCompleted" do
    test "produces a single %MatchCompleted{} with win/loss and game count" do
      record = record_from_fixture("match_game_room_state_changed_completed.log")

      assert [%MatchCompleted{} = event] = Translator.translate(record, @self_user_id)
      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.ended_at == ~U[2026-04-05 19:53:36Z]

      # In the fixture, MatchScope_Match has winningTeamId=1 and the
      # self-user is on teamId=1 (from reservedPlayers[]), so won=true.
      assert event.won == true

      # The fixture's resultList has 3 MatchScope_Game rows.
      assert event.num_games == 3
      assert event.reason == "MatchCompletedReasonType_Success"
    end
  end

  describe "translate/2 — fall-through" do
    test "returns [] for an unrelated raw event type" do
      record = %EventRecord{
        id: 1,
        event_type: "GraphGetGraphState",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"foo":"bar"}),
        processed: false
      }

      assert Translator.translate(record, @self_user_id) == []
    end

    test "returns [] for MatchGameRoomStateChangedEvent with unknown stateType" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          ~s({"matchGameRoomStateChangedEvent":{"gameRoomInfo":{"gameRoomConfig":{"matchId":"x","reservedPlayers":[]},"stateType":"MatchGameRoomStateType_Closed"}}}),
        processed: false
      }

      assert Translator.translate(record, @self_user_id) == []
    end

    test "returns [] on malformed JSON" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "not json",
        processed: false
      }

      assert Translator.translate(record, @self_user_id) == []
    end
  end
end
