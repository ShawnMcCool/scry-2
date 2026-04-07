defmodule Scry2.MtgaLogIngestion.ExtractEventsFromLogTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogIngestion.{Event, ExtractEventsFromLog, ParseWarning}

  # These tests use synthetic fixtures that mimic the dominant
  # `UnityCrossThreadLogger` event header format. Real captured log
  # fragments should be added under `test/fixtures/mtga_logs/` as we
  # encounter them — see ADR-010 (regression tests are append-only).

  describe "parse_chunk/3 — header + simple JSON payload" do
    test "extracts an event with a flat JSON payload" do
      chunk = """
      [UnityCrossThreadLogger]==> EventMatchCreated 4/5/2026 7:12:03 PM
      {"matchId":"abc-123","opponent":"Opponent#12345"}
      """

      assert {[%Event{} = event], []} =
               ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert event.type == "EventMatchCreated"
      assert event.payload == %{"matchId" => "abc-123", "opponent" => "Opponent#12345"}
      assert event.raw_json == ~s({"matchId":"abc-123","opponent":"Opponent#12345"})
      assert event.source_file == "/tmp/fake.log"
      assert is_integer(event.file_offset)
    end

    test "extracts an event with a nested JSON payload (brace balancing)" do
      chunk = """
      [UnityCrossThreadLogger]==> EventDeckSubmit 4/5/2026 7:14:00 PM
      {"deckId":"deck-1","mainDeck":[{"id":91234,"count":4},{"id":91235,"count":3}],"name":"Mono Blue"}
      """

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert event.type == "EventDeckSubmit"
      assert event.payload["deckId"] == "deck-1"
      assert length(event.payload["mainDeck"]) == 2
    end

    test "skips JSON blocks that contain escaped quotes" do
      chunk = """
      [UnityCrossThreadLogger]==> EventDeckSubmit
      {"name":"\\"Quoted\\" Name","deckId":"x"}
      """

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert event.type == "EventDeckSubmit"
      assert event.payload["name"] == ~s("Quoted" Name)
    end

    test "returns an empty list when there is no event header" do
      chunk = """
      Unity engine log line.
      Another line.
      [info] regular Phoenix log
      """

      assert {[], _warnings} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)
    end

    test "file_offset is adjusted by base_offset" do
      chunk = """
      [UnityCrossThreadLogger]==> MatchStart
      {"gameId":"g1"}
      """

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 1_000)

      assert event.file_offset >= 1_000
    end
  end

  describe "parse_chunk/3 — multiple events in one chunk" do
    test "extracts two back-to-back events" do
      chunk = """
      [UnityCrossThreadLogger]==> EventMatchCreated
      {"matchId":"m1"}
      some intervening text
      [UnityCrossThreadLogger]==> MatchStart
      {"gameId":"g1"}
      """

      {events, []} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert length(events) == 2
      assert Enum.map(events, & &1.type) == ["EventMatchCreated", "MatchStart"]
    end
  end

  describe "parse_chunk/3 — malformed payloads" do
    test "skips header without a JSON block" do
      chunk = "[UnityCrossThreadLogger]==> EventMatchCreated\nno json here\n"

      assert {[], _warnings} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 0)
    end

    test "emits json_decode_failed warning for syntactically-complete but invalid JSON" do
      # Brace-balanced but not valid JSON — grab_json_block finds the block,
      # then decode_json_with_warnings reports the failure.
      chunk = "[UnityCrossThreadLogger]==> EventMatchCreated\n{not: valid}\n"

      {[event], warnings} = ExtractEventsFromLog.parse_chunk(chunk, "/tmp/fake.log", 500)

      assert event.type == "EventMatchCreated"
      assert event.payload == nil
      assert event.raw_json == "{not: valid}"

      assert [%ParseWarning{category: :json_decode_failed} = warning] = warnings
      assert warning.file_offset == 500
      assert warning.detail =~ "JSON decode error"
    end
  end

  # ── Real fixtures (ADR-010 — append-only regression tests) ──────────
  #
  # Every fixture below is a real MTGA Player.log block captured from a
  # live client. Opponent PII has been anonymized (Dgdchon → Opponent1,
  # opponent Wizards ID → OPPONENT_USER_ID_1) — the user's own values
  # stay because this is a single-user personal repo.
  #
  # Per ADR-010 these tests are append-only. Never delete or weaken
  # them; fix the parser instead.

  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

  describe "parse_chunk/3 — real fixtures" do
    test "Format A inline: EventJoin request (header + JSON on same line)" do
      chunk = fixture("event_join.log")

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

      assert event.type == "EventJoin"
      assert event.mtga_timestamp == nil
      assert event.payload["id"] == "2c568a83-fbc0-4f79-aebd-88242e571a72"
      # request is a double-encoded JSON string — preserved verbatim in raw_json
      assert is_binary(event.payload["request"])
      assert event.payload["request"] =~ "Traditional_Ladder"
      assert event.raw_json =~ "2c568a83-fbc0-4f79-aebd-88242e571a72"
    end

    test "Format B: MatchGameRoomStateChangedEvent state=Playing (match created from lobby)" do
      chunk = fixture("match_game_room_state_changed_playing.log")

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

      assert event.type == "MatchGameRoomStateChangedEvent"

      # Timestamp extracted from the Format B header: "4/5/2026 7:18:40 PM"
      assert event.mtga_timestamp == ~U[2026-04-05 19:18:40Z]

      # Real match id from the nested payload
      match_id =
        get_in(event.payload, [
          "matchGameRoomStateChangedEvent",
          "gameRoomInfo",
          "gameRoomConfig",
          "matchId"
        ])

      assert match_id == "008b1926-09a8-40b4-872d-fa987588740c"

      assert get_in(event.payload, ["matchGameRoomStateChangedEvent", "gameRoomInfo", "stateType"]) ==
               "MatchGameRoomStateType_Playing"

      # Opponent info is present and anonymized (fixture hygiene)
      reserved_players =
        get_in(event.payload, [
          "matchGameRoomStateChangedEvent",
          "gameRoomInfo",
          "gameRoomConfig",
          "reservedPlayers"
        ])

      assert length(reserved_players) == 2
      player_names = Enum.map(reserved_players, & &1["playerName"])
      assert "Opponent1" in player_names
    end

    test "Format B: MatchGameRoomStateChangedEvent state=MatchCompleted (final result)" do
      chunk = fixture("match_game_room_state_changed_completed.log")

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

      assert event.type == "MatchGameRoomStateChangedEvent"
      assert event.mtga_timestamp == ~U[2026-04-05 19:53:36Z]

      assert get_in(event.payload, ["matchGameRoomStateChangedEvent", "gameRoomInfo", "stateType"]) ==
               "MatchGameRoomStateType_MatchCompleted"

      # Final result carries per-game results + overall match winner
      final_result =
        get_in(event.payload, [
          "matchGameRoomStateChangedEvent",
          "gameRoomInfo",
          "finalMatchResult"
        ])

      assert final_result["matchId"] == "008b1926-09a8-40b4-872d-fa987588740c"
      assert final_result["matchCompletedReason"] == "MatchCompletedReasonType_Success"

      # Three game rows + one match-scope row = 4 results
      assert length(final_result["resultList"]) == 4

      match_row = Enum.find(final_result["resultList"], &(&1["scope"] == "MatchScope_Match"))
      assert match_row["winningTeamId"] == 1
    end

    test "Format B: GreToClientEvent connectResp (carries deck data for future mapper work)" do
      chunk = fixture("gre_to_client_event_connect_resp.log")

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

      assert event.type == "GreToClientEvent"
      assert event.mtga_timestamp == ~U[2026-04-05 19:18:40Z]

      # This fixture is retained for the next session's deck-submission
      # mapping work. Verify the key nested path exists so we know the
      # parser preserves the full GRE message stream.
      messages = get_in(event.payload, ["greToClientEvent", "greToClientMessages"])
      assert is_list(messages)

      connect_resp = Enum.find(messages, &(&1["type"] == "GREMessageType_ConnectResp"))
      assert connect_resp
      assert is_list(get_in(connect_resp, ["connectResp", "deckMessage", "deckCards"]))
    end

    test "Format A response: RankGetCombinedRankInfo three-line pattern (timestamp + bare <== + JSON)" do
      chunk = fixture("rank_get_combined_rank_info_response.log")

      {[event], []} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

      assert event.type == "RankGetCombinedRankInfo"
      assert event.mtga_timestamp == ~U[2026-04-06 18:47:51Z]
      assert event.payload["constructedClass"] == "Diamond"
      assert event.payload["constructedLevel"] == 4
      assert event.payload["limitedClass"] == "Silver"
    end
  end
end
