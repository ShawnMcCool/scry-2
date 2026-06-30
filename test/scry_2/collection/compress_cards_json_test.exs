defmodule Scry2.Collection.CompressCardsJsonTest do
  use Scry2.DataCase, async: true

  alias Scry2.Collection
  alias Scry2.Collection.Snapshot
  alias Scry2.Events.RawCompression
  alias Scry2.Repo

  # Inserts a snapshot with cards_json stored verbatim (plaintext) — simulates
  # a legacy pre-ADR-042 row by passing cards_json directly (not via :entries,
  # which would compress it).
  defp insert_legacy!(plaintext_json) do
    %Snapshot{}
    |> Snapshot.changeset(%{
      snapshot_ts: DateTime.utc_now(),
      reader_version: "v0.0.0-test",
      reader_confidence: "fallback_scan",
      card_count: 1,
      total_copies: 2,
      cards_json: plaintext_json
    })
    |> Repo.insert!()
  end

  defp reload(id), do: Repo.get!(Snapshot, id)

  test "compresses legacy plaintext cards_json, keeping entries decodable" do
    # Realistic collection size — tiny payloads don't beat zstd frame overhead.
    entries = for n <- 1..1000, do: %{"arena_id" => n, "count" => rem(n, 4) + 1}
    plaintext = Jason.encode!(entries)
    legacy = insert_legacy!(plaintext)
    refute RawCompression.compressed?(legacy.cards_json)

    stats = Collection.compress_existing_cards_json!()

    compressed = reload(legacy.id)
    assert RawCompression.compressed?(compressed.cards_json)

    assert Snapshot.decode_entries(compressed.cards_json) ==
             Enum.map(entries, &{&1["arena_id"], &1["count"]})

    assert stats.compressed == 1
    assert stats.bytes_after < stats.bytes_before
  end

  test "is idempotent / resumable" do
    insert_legacy!(Jason.encode!([%{"arena_id" => 1, "count" => 1}]))

    assert Collection.compress_existing_cards_json!().compressed == 1
    assert Collection.compress_existing_cards_json!().compressed == 0
  end
end
