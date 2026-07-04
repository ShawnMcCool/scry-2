defmodule Scry2.Uplink.WireEventTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.EventRecord
  alias Scry2.Uplink.WireEvent

  defp sample_record do
    %EventRecord{
      id: 42,
      event_type: "match_created",
      payload: %{"mtga_match_id" => "abc-123", "format" => "Standard"},
      mtga_source_id: 1001,
      mtga_timestamp: ~U[2026-06-01 12:00:00Z],
      sequence: 0,
      player_id: 5,
      match_id: "abc-123",
      draft_id: nil,
      session_id: "sess-9"
    }
  end

  describe "encode/1" do
    test "produces a wire map with the upload key and domain fields" do
      wire = WireEvent.encode(sample_record())

      assert wire["upload_key"] == "r:1001:match_created:0"
      assert wire["event_type"] == "match_created"
      assert wire["payload"] == %{"mtga_match_id" => "abc-123", "format" => "Standard"}
      assert wire["mtga_source_id"] == 1001
      assert wire["mtga_timestamp"] == "2026-06-01T12:00:00Z"
      assert wire["sequence"] == 0
      assert wire["match_id"] == "abc-123"
      assert wire["draft_id"] == nil
      assert wire["session_id"] == "sess-9"
    end

    test "excludes client-local fields (local id and player_id)" do
      wire = WireEvent.encode(sample_record())

      refute Map.has_key?(wire, "id")
      refute Map.has_key?(wire, "player_id")
    end

    test "encodes a nil mtga_timestamp as nil" do
      wire = WireEvent.encode(%{sample_record() | mtga_timestamp: nil})
      assert wire["mtga_timestamp"] == nil
    end
  end

  describe "decode/1" do
    test "round-trips encode/1 into server-insert attrs" do
      attrs = sample_record() |> WireEvent.encode() |> WireEvent.decode()

      assert attrs == %{
               upload_key: "r:1001:match_created:0",
               event_type: "match_created",
               payload: %{"mtga_match_id" => "abc-123", "format" => "Standard"},
               mtga_source_id: 1001,
               mtga_timestamp: ~U[2026-06-01 12:00:00Z],
               sequence: 0,
               match_id: "abc-123",
               draft_id: nil,
               session_id: "sess-9"
             }
    end

    test "decodes a nil mtga_timestamp as nil" do
      attrs = %{sample_record() | mtga_timestamp: nil} |> WireEvent.encode() |> WireEvent.decode()
      assert attrs.mtga_timestamp == nil
    end
  end
end
