defmodule Scry2.Economy.IngestMemoryGrantsTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection.Diff
  alias Scry2.Economy
  alias Scry2.Economy.{CardGrant, IngestMemoryGrants}
  alias Scry2.Topics

  import Scry2.TestFactory

  describe "subscriber lifecycle" do
    test "starts and subscribes to collection:diffs" do
      name = :"ingest_memory_grants_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestMemoryGrants.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "diff handling" do
    test "records a memory-diff card-grant batch when collection grew" do
      Topics.subscribe(Topics.economy_updates())

      name = :"ingest_memory_grants_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestMemoryGrants.start_link(name: name)

      prev = create_collection_snapshot(entries: [{1, 1}])
      next = create_collection_snapshot(entries: [{1, 1}, {42, 1}, {99, 1}])

      diff = %Diff{from_snapshot_id: prev.id, to_snapshot_id: next.id}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      :sys.get_state(pid)

      assert [grant] = Economy.list_card_grants()
      assert grant.source == Economy.memory_diff_source()
      assert grant.card_count == 2
      assert grant.to_snapshot_id == next.id
      assert_receive {:economy_updated, :card_grant}, 100

      GenServer.stop(pid)
    end

    test "no row + no broadcast when nothing changed" do
      Topics.subscribe(Topics.economy_updates())

      name = :"ingest_memory_grants_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestMemoryGrants.start_link(name: name)

      prev = create_collection_snapshot(entries: [{1, 1}])
      next = create_collection_snapshot(entries: [{1, 1}])

      diff = %Diff{from_snapshot_id: prev.id, to_snapshot_id: next.id}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      :sys.get_state(pid)

      assert Economy.list_card_grants() == []
      refute_receive {:economy_updated, :card_grant}, 50

      GenServer.stop(pid)
    end

    test "tolerates missing to_snapshot without crashing" do
      name = :"ingest_memory_grants_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestMemoryGrants.start_link(name: name)

      diff = %Diff{from_snapshot_id: nil, to_snapshot_id: 99_999_999}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      :sys.get_state(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "is idempotent — duplicate diff broadcasts upsert nothing" do
      name = :"ingest_memory_grants_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestMemoryGrants.start_link(name: name)

      prev = create_collection_snapshot(entries: [])
      next = create_collection_snapshot(entries: [{42, 1}])

      diff = %Diff{from_snapshot_id: prev.id, to_snapshot_id: next.id}

      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})
      :sys.get_state(pid)

      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})
      :sys.get_state(pid)

      assert Repo.aggregate(CardGrant, :count, :id) == 1

      GenServer.stop(pid)
    end
  end
end
