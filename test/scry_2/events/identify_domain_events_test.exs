defmodule Scry2.Events.IdentifyDomainEventsTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.{DeckSubmitted, IdentifyDomainEvents, MatchCompleted, MatchCreated}
  alias Scry2.MtgaLogIngestion.{Event, ExtractEventsFromLog, EventRecord}

  # The self_user_id baked into the captured fixtures.
  @self_user_id "D0FECB2AF1E7FE24"

  # Reads a real fixture and returns a synthetic %EventRecord{} with the
  # fixture's raw JSON and parsed timestamp. Pure setup — no DB.
  defp record_from_fixture(fixture_name) do
    path = Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", fixture_name])
    chunk = File.read!(path)
    [%Event{} = event] = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

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

      assert [%MatchCreated{} = event] = IdentifyDomainEvents.translate(record, @self_user_id)
      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.event_name == "Traditional_Ladder"
      assert event.opponent_screen_name == "Opponent1"
      assert event.occurred_at == ~U[2026-04-05 19:18:40Z]
    end

    test "falls back to systemSeatId != 1 for opponent when self_user_id is nil" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert [%MatchCreated{} = event] = IdentifyDomainEvents.translate(record, nil)
      assert event.opponent_screen_name == "Opponent1"
      assert event.event_name == "Traditional_Ladder"
    end
  end

  describe "translate/2 — MatchGameRoomStateChangedEvent, stateType=MatchCompleted" do
    test "produces a single %MatchCompleted{} with win/loss and game count" do
      record = record_from_fixture("match_game_room_state_changed_completed.log")

      assert [%MatchCompleted{} = event] = IdentifyDomainEvents.translate(record, @self_user_id)
      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.occurred_at == ~U[2026-04-05 19:53:36Z]

      # In the fixture, MatchScope_Match has winningTeamId=1 and the
      # self-user is on teamId=1 (from reservedPlayers[]), so won=true.
      assert event.won == true

      # The fixture's resultList has 3 MatchScope_Game rows.
      assert event.num_games == 3
      assert event.reason == "MatchCompletedReasonType_Success"
    end
  end

  describe "translate/2 — GreToClientEvent, ConnectResp → DeckSubmitted" do
    test "produces a %DeckSubmitted{} with aggregated deck cards from the ConnectResp fixture" do
      record = record_from_fixture("gre_to_client_event_connect_resp.log")

      events = IdentifyDomainEvents.translate(record, @self_user_id)

      assert [%DeckSubmitted{} = deck_event] = events
      assert deck_event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert deck_event.mtga_deck_id == "008b1926-09a8-40b4-872d-fa987588740c:seat1"
      assert deck_event.occurred_at == ~U[2026-04-05 19:18:40Z]

      # The fixture's deckCards has 60 entries (a 60-card deck).
      total_main = Enum.reduce(deck_event.main_deck, 0, fn card, acc -> acc + card.count end)
      assert total_main == 60

      # Verify aggregation: arena_id 67810 appears 4 times in the flat array.
      card_67810 = Enum.find(deck_event.main_deck, &(&1.arena_id == 67810))
      assert card_67810.count == 4

      # Sideboard has 15 entries in the fixture.
      total_sb = Enum.reduce(deck_event.sideboard, 0, fn card, acc -> acc + card.count end)
      assert total_sb == 15
    end

    test "returns [] when GreToClientEvent has no ConnectResp" do
      record = %EventRecord{
        id: 1,
        event_type: "GreToClientEvent",
        mtga_timestamp: ~U[2026-04-05 19:18:40Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "greToClientEvent" => %{
              "greToClientMessages" => [
                %{"type" => "GREMessageType_DieRollResultsResp", "systemSeatIds" => [1, 2]}
              ]
            }
          }),
        processed: false
      }

      assert IdentifyDomainEvents.translate(record, nil) == []
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

      assert IdentifyDomainEvents.translate(record, @self_user_id) == []
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

      assert IdentifyDomainEvents.translate(record, @self_user_id) == []
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

      assert IdentifyDomainEvents.translate(record, @self_user_id) == []
    end
  end

  describe "event discovery registry (ADR-020)" do
    test "known_event_types includes handled types" do
      known = IdentifyDomainEvents.known_event_types()
      assert MapSet.member?(known, "MatchGameRoomStateChangedEvent")
      assert MapSet.member?(known, "GreToClientEvent")
    end

    test "known_event_types includes explicitly ignored types" do
      known = IdentifyDomainEvents.known_event_types()
      assert MapSet.member?(known, "GraphGetGraphState")
      assert MapSet.member?(known, "ClientToGreuimessage")
    end

    test "recognized? returns false for unknown types" do
      refute IdentifyDomainEvents.recognized?("SomeNewMtgaEvent")
    end

    test "recognized? returns true for handled types" do
      assert IdentifyDomainEvents.recognized?("MatchGameRoomStateChangedEvent")
    end

    test "recognized? returns true for ignored types" do
      assert IdentifyDomainEvents.recognized?("GraphGetGraphState")
    end
  end
end
