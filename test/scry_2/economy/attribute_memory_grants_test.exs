defmodule Scry2.Economy.AttributeMemoryGrantsTest do
  use ExUnit.Case, async: true

  alias Scry2.Economy.AttributeMemoryGrants

  import Scry2.TestFactory

  describe "attribute/3" do
    test "returns [] when prev is nil (bootstrap snapshot)" do
      next = build_collection_snapshot(entries: [{1, 1}, {2, 1}])
      assert AttributeMemoryGrants.attribute(nil, next, MapSet.new()) == []
    end

    test "returns [] when nothing changed between snapshots" do
      prev = build_collection_snapshot(entries: [{1, 1}])
      next = build_collection_snapshot(entries: [{1, 1}])
      assert AttributeMemoryGrants.attribute(prev, next, MapSet.new()) == []
    end

    test "emits one grant row per new copy of a brand-new arena_id" do
      prev = build_collection_snapshot(entries: [{1, 1}])
      next = build_collection_snapshot(entries: [{1, 1}, {42, 1}])

      result = AttributeMemoryGrants.attribute(prev, next, MapSet.new())

      assert result == [
               %{arena_id: 42, set_code: nil, card_added: true, vault_progress: 0}
             ]
    end

    test "emits N rows when an arena_id appears with count N" do
      prev = build_collection_snapshot(entries: [])
      next = build_collection_snapshot(entries: [{42, 4}])

      result = AttributeMemoryGrants.attribute(prev, next, MapSet.new())

      assert length(result) == 4
      assert Enum.all?(result, &(&1.arena_id == 42))
    end

    test "emits delta-many rows when an existing arena_id's count grows" do
      prev = build_collection_snapshot(entries: [{1, 1}])
      next = build_collection_snapshot(entries: [{1, 3}])

      result = AttributeMemoryGrants.attribute(prev, next, MapSet.new())

      assert length(result) == 2
      assert Enum.all?(result, &(&1.arena_id == 1))
    end

    test "emits rows for every distinct arena_id that grew" do
      prev = build_collection_snapshot(entries: [{1, 1}])
      next = build_collection_snapshot(entries: [{1, 1}, {42, 1}, {99, 2}])

      result = AttributeMemoryGrants.attribute(prev, next, MapSet.new())

      ids = result |> Enum.map(& &1.arena_id) |> Enum.sort()
      assert ids == [42, 99, 99]
    end

    test "excludes arena_ids in the exclude set (already attributed elsewhere)" do
      prev = build_collection_snapshot(entries: [])
      next = build_collection_snapshot(entries: [{42, 1}, {99, 1}])
      exclude = MapSet.new([42])

      result = AttributeMemoryGrants.attribute(prev, next, exclude)

      assert result == [
               %{arena_id: 99, set_code: nil, card_added: true, vault_progress: 0}
             ]
    end

    test "excludes the entire incremented run when an arena_id is excluded" do
      prev = build_collection_snapshot(entries: [{1, 1}])
      next = build_collection_snapshot(entries: [{1, 4}])
      exclude = MapSet.new([1])

      assert AttributeMemoryGrants.attribute(prev, next, exclude) == []
    end

    test "ignores arena_ids whose count decreased" do
      prev = build_collection_snapshot(entries: [{1, 4}])
      next = build_collection_snapshot(entries: [{1, 2}])

      assert AttributeMemoryGrants.attribute(prev, next, MapSet.new()) == []
    end

    test "ignores arena_ids that disappeared entirely" do
      prev = build_collection_snapshot(entries: [{1, 1}, {2, 1}])
      next = build_collection_snapshot(entries: [{1, 1}])

      assert AttributeMemoryGrants.attribute(prev, next, MapSet.new()) == []
    end
  end
end
