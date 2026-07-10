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

  describe "ensure_compressed/1 (idempotent)" do
    test "compresses plaintext" do
      assert RawCompression.compressed?(RawCompression.ensure_compressed("{}"))
    end

    test "leaves an already-compressed frame untouched (no double compression)" do
      once = RawCompression.compress(~s({"a":1}))
      assert RawCompression.ensure_compressed(once) == once
      assert RawCompression.decompress(RawCompression.ensure_compressed(once)) == ~s({"a":1})
    end
  end

  describe "decompress/1 reads frames written by earlier releases" do
    # Rows compressed before v0.52.1 were written by the ezstd NIF
    # (dropped for the OTP 28 stdlib :zstd — ezstd could not build on
    # Windows). This frame was produced by :ezstd.compress/2 at level 19
    # and pins the on-disk contract: every historical row must stay
    # decodable by whatever implementation the codec uses.
    @ezstd_written_frame Base.decode16!("28B52FFD200F7900007B22726177223A226576656E74227D")

    test "decompresses a frame produced by the ezstd-based codec" do
      assert RawCompression.decompress(@ezstd_written_frame) == ~s({"raw":"event"})
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
