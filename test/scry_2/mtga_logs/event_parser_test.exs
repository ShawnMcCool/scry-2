defmodule Scry2.MtgaLogs.EventParserTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogs.{Event, EventParser}

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

      assert [%Event{} = event] = EventParser.parse_chunk(chunk, "/tmp/fake.log", 0)

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

      [event] = EventParser.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert event.type == "EventDeckSubmit"
      assert event.payload["deckId"] == "deck-1"
      assert length(event.payload["mainDeck"]) == 2
    end

    test "skips JSON blocks that contain escaped quotes" do
      chunk = """
      [UnityCrossThreadLogger]==> EventDeckSubmit
      {"name":"\\"Quoted\\" Name","deckId":"x"}
      """

      [event] = EventParser.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert event.type == "EventDeckSubmit"
      assert event.payload["name"] == ~s("Quoted" Name)
    end

    test "returns an empty list when there is no event header" do
      chunk = """
      Unity engine log line.
      Another line.
      [info] regular Phoenix log
      """

      assert EventParser.parse_chunk(chunk, "/tmp/fake.log", 0) == []
    end

    test "file_offset is adjusted by base_offset" do
      chunk = """
      [UnityCrossThreadLogger]==> MatchStart
      {"gameId":"g1"}
      """

      [event] = EventParser.parse_chunk(chunk, "/tmp/fake.log", 1_000)

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

      events = EventParser.parse_chunk(chunk, "/tmp/fake.log", 0)

      assert length(events) == 2
      assert Enum.map(events, & &1.type) == ["EventMatchCreated", "MatchStart"]
    end
  end

  describe "parse_chunk/3 — malformed payloads" do
    test "skips header without a JSON block" do
      chunk = "[UnityCrossThreadLogger]==> EventMatchCreated\nno json here\n"

      assert EventParser.parse_chunk(chunk, "/tmp/fake.log", 0) == []
    end
  end
end
