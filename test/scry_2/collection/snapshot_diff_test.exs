defmodule Scry2.Collection.SnapshotDiffTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Snapshot
  alias Scry2.Collection.SnapshotDiff
  alias Scry2.TestFactory

  describe "diff/2" do
    test "no previous snapshot returns the full collection as acquired" do
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 1}, {30_002, 2}])

      assert SnapshotDiff.diff(nil, next) == %{
               acquired: %{30_001 => 1, 30_002 => 2},
               removed: %{}
             }
    end

    test "identical snapshots produce an empty diff" do
      entries = [{30_001, 4}, {30_002, 2}, {30_003, 1}]
      prev = TestFactory.build_collection_snapshot(entries: entries)
      next = TestFactory.build_collection_snapshot(entries: entries)

      assert SnapshotDiff.diff(prev, next) == %{acquired: %{}, removed: %{}}
    end

    test "card added (was absent) appears in acquired with full count" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 1}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 1}, {30_002, 3}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{30_002 => 3},
               removed: %{}
             }
    end

    test "card removed (now absent) appears in removed with full count" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 1}, {30_002, 3}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 1}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{},
               removed: %{30_002 => 3}
             }
    end

    test "count increased: only the delta is reported in acquired" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 1}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 4}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{30_001 => 3},
               removed: %{}
             }
    end

    test "count decreased: only the delta is reported in removed" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 4}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 1}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{},
               removed: %{30_001 => 3}
             }
    end

    test "count went to zero: card appears in removed with full prior count" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 2}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 0}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{},
               removed: %{30_001 => 2}
             }
    end

    test "count came up from zero: card appears in acquired with full new count" do
      prev = TestFactory.build_collection_snapshot(entries: [{30_001, 0}])
      next = TestFactory.build_collection_snapshot(entries: [{30_001, 2}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{30_001 => 2},
               removed: %{}
             }
    end

    test "mixed acquisitions and removals are reported together" do
      prev =
        TestFactory.build_collection_snapshot(entries: [{30_001, 1}, {30_002, 4}, {30_003, 2}])

      next =
        TestFactory.build_collection_snapshot(entries: [{30_001, 4}, {30_003, 1}, {30_004, 1}])

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{30_001 => 3, 30_004 => 1},
               removed: %{30_002 => 4, 30_003 => 1}
             }
    end

    test "totals/0 returns sums of both maps" do
      diff = %{acquired: %{30_001 => 3, 30_004 => 1}, removed: %{30_002 => 4, 30_003 => 1}}

      assert SnapshotDiff.totals(diff) == %{total_acquired: 4, total_removed: 5}
    end
  end

  describe "decoded card-count round-trip" do
    test "diff operates on Snapshot rows whose cards_json was JSON-encoded" do
      prev_json = Snapshot.encode_entries([{30_001, 2}])
      next_json = Snapshot.encode_entries([{30_001, 4}, {30_002, 1}])

      prev = %Snapshot{cards_json: prev_json}
      next = %Snapshot{cards_json: next_json}

      assert SnapshotDiff.diff(prev, next) == %{
               acquired: %{30_001 => 2, 30_002 => 1},
               removed: %{}
             }
    end
  end
end
