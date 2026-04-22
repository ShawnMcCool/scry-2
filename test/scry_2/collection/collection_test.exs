defmodule Scry2.CollectionTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection
  alias Scry2.Collection.Snapshot
  alias Scry2.TestFactory

  describe "current/0 and list_snapshots/1" do
    test "current/0 returns nil when no snapshots exist" do
      assert Collection.current() == nil
    end

    test "current/0 returns the most recent snapshot" do
      _older =
        TestFactory.create_collection_snapshot(
          snapshot_ts: DateTime.add(DateTime.utc_now(), -60, :second),
          entries: [{30_001, 1}]
        )

      newer = TestFactory.create_collection_snapshot(entries: [{30_002, 2}])

      assert %Snapshot{id: id} = Collection.current()
      assert id == newer.id
    end

    test "list_snapshots/1 returns rows newest-first and respects :limit" do
      for i <- 1..3 do
        TestFactory.create_collection_snapshot(
          snapshot_ts: DateTime.add(DateTime.utc_now(), i, :second),
          entries: [{30_000 + i, 1}]
        )
      end

      [first, second] = Collection.list_snapshots(limit: 2)
      assert first.snapshot_ts > second.snapshot_ts
    end
  end

  describe "reader_enabled? / enable_reader! / disable_reader!" do
    test "defaults to disabled" do
      refute Collection.reader_enabled?()
    end

    test "enable/disable round-trip through Settings" do
      :ok = Collection.enable_reader!()
      assert Collection.reader_enabled?()

      :ok = Collection.disable_reader!()
      refute Collection.reader_enabled?()
    end
  end

  describe "save_snapshot/1" do
    test "persists the result and broadcasts :snapshot_saved" do
      Scry2.Topics.subscribe(Scry2.Topics.collection_snapshots())

      result = %{
        entries: [{30_001, 2}, {91_234, 1}],
        card_count: 2,
        total_copies: 3,
        reader_confidence: "fallback_scan",
        entries_start: 0x1000,
        region_start: 0x0
      }

      assert {:ok, %Snapshot{} = snapshot} = Collection.save_snapshot(result)
      assert snapshot.card_count == 2
      assert snapshot.total_copies == 3
      assert snapshot.reader_confidence == "fallback_scan"

      assert_receive {:snapshot_saved, %Snapshot{id: id}}
      assert id == snapshot.id
    end

    test "passes through walker-only fields when present" do
      result = %{
        entries: [{30_001, 1}],
        card_count: 1,
        total_copies: 1,
        reader_confidence: "walker",
        wildcards_common: 50,
        wildcards_uncommon: 40,
        wildcards_rare: 30,
        wildcards_mythic: 20,
        gold: 12_345,
        gems: 678,
        vault_progress: 77,
        mtga_build_hint: "2026.03.01.12345"
      }

      assert {:ok, snapshot} = Collection.save_snapshot(result)
      assert snapshot.wildcards_rare == 30
      assert snapshot.gold == 12_345
      assert snapshot.mtga_build_hint == "2026.03.01.12345"
    end
  end
end
