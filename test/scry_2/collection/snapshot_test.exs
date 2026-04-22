defmodule Scry2.Collection.SnapshotTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection.Snapshot
  alias Scry2.TestFactory

  describe "changeset/2" do
    test "derives cards_json, card_count, and total_copies from :entries" do
      entries = [{30_001, 2}, {30_002, 3}]

      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          entries: entries,
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0-test",
          reader_confidence: "fallback_scan"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :card_count) == 2
      assert Ecto.Changeset.get_change(changeset, :total_copies) == 5

      cards_json = Ecto.Changeset.get_change(changeset, :cards_json)
      decoded = Snapshot.decode_entries(cards_json)
      assert decoded == entries
    end

    test "rejects unknown reader_confidence values" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          entries: [],
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "clairvoyance"
        })

      refute changeset.valid?
      assert %{reader_confidence: [_]} = errors_on(changeset)
    end

    test "requires the baseline fields" do
      changeset = Snapshot.changeset(%Snapshot{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:snapshot_ts]
      assert errors[:reader_version]
      assert errors[:reader_confidence]
    end

    test "rejects negative card_count / total_copies" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "walker",
          cards_json: "[]",
          card_count: -1,
          total_copies: -5
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:card_count]
      assert errors[:total_copies]
    end

    test "accepts walker reader_confidence plus the walker-only fields" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "walker",
          entries: [{30_001, 1}],
          wildcards_common: 50,
          wildcards_uncommon: 40,
          wildcards_rare: 30,
          wildcards_mythic: 20,
          gold: 99_999,
          gems: 1234,
          vault_progress: 55
        })

      assert changeset.valid?
    end
  end

  describe "entries round-trip via encode/decode" do
    test "re-materialises entries unchanged" do
      entries = [{30_001, 1}, {91_234, 4}, {200_000, 2}]
      decoded = entries |> Snapshot.encode_entries() |> Snapshot.decode_entries()
      assert decoded == entries
    end
  end

  describe "create_collection_snapshot factory" do
    test "persists via changeset and round-trips cards_json" do
      snapshot = TestFactory.create_collection_snapshot(entries: [{30_001, 3}, {91_234, 1}])

      reloaded = Repo.get!(Snapshot, snapshot.id)

      assert reloaded.card_count == 2
      assert reloaded.total_copies == 4
      assert Snapshot.decode_entries(reloaded.cards_json) == [{30_001, 3}, {91_234, 1}]
    end
  end
end
