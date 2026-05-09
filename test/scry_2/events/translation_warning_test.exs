defmodule Scry2.Events.TranslationWarningTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.TranslationWarning

  test "category, event_type, and detail are required" do
    assert_raise ArgumentError, fn ->
      struct!(TranslationWarning, category: :json_decode_failed)
    end
  end

  test "raw_event_id is optional and defaults to nil" do
    warning = %TranslationWarning{
      category: :payload_extraction_failed,
      event_type: "MatchGameRoomStateChangedEvent",
      detail: "missing gameRoomInfo"
    }

    assert warning.raw_event_id == nil
    assert warning.event_type == "MatchGameRoomStateChangedEvent"
  end

  test "carries raw_event_id when supplied" do
    warning = %TranslationWarning{
      category: :json_decode_failed,
      raw_event_id: 4_242,
      event_type: "GreToClientEvent",
      detail: "Jason.DecodeError at byte 12"
    }

    assert warning.raw_event_id == 4_242
  end
end
