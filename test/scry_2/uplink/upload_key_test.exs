defmodule Scry2.Uplink.UploadKeyTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.EventRecord
  alias Scry2.Uplink.UploadKey

  describe "derive/1" do
    test "raw-derived events key on (mtga_source_id, event_type, sequence)" do
      record = %EventRecord{
        id: 42,
        mtga_source_id: 1001,
        event_type: "match_created",
        sequence: 0
      }

      assert UploadKey.derive(record) == "r:1001:match_created:0"
    end

    test "the raw-derived key ignores the local id (stable across retranslation)" do
      before = %EventRecord{
        id: 42,
        mtga_source_id: 1001,
        event_type: "match_created",
        sequence: 0
      }

      after_retranslate = %EventRecord{
        id: 99,
        mtga_source_id: 1001,
        event_type: "match_created",
        sequence: 0
      }

      assert UploadKey.derive(before) == UploadKey.derive(after_retranslate)
    end

    test "distinct sequences under one raw source get distinct keys" do
      a = %EventRecord{id: 1, mtga_source_id: 1001, event_type: "mulligan_offered", sequence: 0}
      b = %EventRecord{id: 2, mtga_source_id: 1001, event_type: "mulligan_offered", sequence: 1}

      refute UploadKey.derive(a) == UploadKey.derive(b)
    end

    test "synthetic (nil-source) events key on their local id" do
      record = %EventRecord{
        id: 7,
        mtga_source_id: nil,
        event_type: "session_started",
        sequence: 0
      }

      assert UploadKey.derive(record) == "s:7:session_started"
    end
  end
end
