defmodule Scry2.MtgaLogIngestion.ParseWarningTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogIngestion.ParseWarning

  test "all enforced keys must be supplied" do
    assert_raise ArgumentError, fn ->
      struct!(ParseWarning, category: :json_decode_failed, file_offset: 0)
    end
  end

  test "builds a structured warning with the expected shape" do
    warning = %ParseWarning{
      category: :json_decode_failed,
      file_offset: 4096,
      detail: "unexpected token at byte 12"
    }

    assert warning.category == :json_decode_failed
    assert warning.file_offset == 4096
    assert warning.detail == "unexpected token at byte 12"
  end

  test "supports the timestamp_parse_failed category" do
    warning = %ParseWarning{
      category: :timestamp_parse_failed,
      file_offset: 0,
      detail: "no leading [UnityCrossThreadLogger] timestamp"
    }

    assert warning.category == :timestamp_parse_failed
  end
end
