defmodule Scry2.Events.RawCompressionTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.RawCompression

  describe "compress/1 + decompress/1 round-trip" do
    test "round-trips a typical MTGA-shaped JSON payload" do
      payload = ~s({"transactionId":"abc-123","greToClientEvent":{"greToClientMessages":[1,2,3]}})

      compressed = RawCompression.compress(payload)
      assert RawCompression.decompress(compressed) == payload
    end

    test "round-trips an empty-object payload" do
      assert RawCompression.decompress(RawCompression.compress("{}")) == "{}"
    end

    test "round-trips a large, repetitive payload (the GreToClientEvent shape)" do
      payload = ~s({"x":#{String.duplicate("\"board state \", ", 500)}"end"})

      compressed = RawCompression.compress(payload)
      assert byte_size(compressed) < byte_size(payload)
      assert RawCompression.decompress(compressed) == payload
    end
  end

  describe "compressed framing" do
    test "compress/1 output begins with the zstd magic bytes" do
      assert <<0x28, 0xB5, 0x2F, 0xFD, _rest::binary>> = RawCompression.compress("{}")
    end

    test "compressed?/1 distinguishes compressed frames from plaintext" do
      assert RawCompression.compressed?(RawCompression.compress("{}"))
      refute RawCompression.compressed?("{}")
      refute RawCompression.compressed?(~s({"a":1}))
    end
  end

  describe "decompress/1 legacy passthrough" do
    # The table holds a mix of legacy plaintext rows (pre-migration) and
    # compressed rows. MTGA raw_json always starts with '{' (0x7B), never the
    # zstd magic 0x28 — so decompress can safely pass plaintext through.
    test "returns plaintext JSON unchanged when it is not a zstd frame" do
      plaintext = ~s({"already":"plain text json"})
      assert RawCompression.decompress(plaintext) == plaintext
    end

    test "passes through a legacy empty-object row" do
      assert RawCompression.decompress("{}") == "{}"
    end
  end
end
