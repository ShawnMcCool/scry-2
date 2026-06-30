defmodule Scry2.MtgaLogIngestion.RawCompressionBackfillTest do
  use Scry2.DataCase, async: true

  alias Scry2.Events.RawCompression
  alias Scry2.MtgaLogIngestion.{EventRecord, RawCompressionBackfill}
  alias Scry2.Repo

  # Inserts a row with raw_json stored verbatim (plaintext) — simulates a
  # legacy pre-ADR-042 row, bypassing the compressing write seam.
  defp insert_legacy!(offset, raw_json) do
    %EventRecord{}
    |> EventRecord.changeset(%{
      event_type: "GreToClientEvent",
      file_offset: offset,
      source_file: "/tmp/backfill-test.log",
      raw_json: raw_json
    })
    |> Repo.insert!()
  end

  defp reload(id), do: Repo.get!(EventRecord, id)

  test "compresses legacy plaintext rows and leaves them decodable" do
    payload = ~s({"greToClientEvent":{"messages":[1,2,3]}})
    legacy = insert_legacy!(1, payload)
    refute RawCompression.compressed?(legacy.raw_json)

    stats = RawCompressionBackfill.run(batch_size: 10)

    compressed = reload(legacy.id)
    assert RawCompression.compressed?(compressed.raw_json)
    assert RawCompression.decompress(compressed.raw_json) == payload
    assert stats.compressed == 1
    assert stats.scanned == 1
  end

  test "skips already-compressed rows (idempotent / resumable)" do
    payload = ~s({"a":1})
    insert_legacy!(1, payload)

    first = RawCompressionBackfill.run(batch_size: 10)
    assert first.compressed == 1

    second = RawCompressionBackfill.run(batch_size: 10)
    assert second.scanned == 1
    assert second.compressed == 0
  end

  test "handles a mix of legacy and already-compressed rows across batches" do
    legacy = insert_legacy!(1, ~s({"legacy":true}))
    precompressed = insert_legacy!(2, RawCompression.compress(~s({"already":true})))

    stats = RawCompressionBackfill.run(batch_size: 1)

    assert stats.scanned == 2
    assert stats.compressed == 1
    assert RawCompression.decompress(reload(legacy.id).raw_json) == ~s({"legacy":true})
    assert RawCompression.decompress(reload(precompressed.id).raw_json) == ~s({"already":true})
  end
end
