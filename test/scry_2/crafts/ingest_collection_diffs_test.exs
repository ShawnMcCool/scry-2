defmodule Scry2.Crafts.IngestCollectionDiffsTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection
  alias Scry2.Collection.Diff
  alias Scry2.Crafts
  alias Scry2.Crafts.IngestCollectionDiffs
  alias Scry2.Topics

  import Scry2.TestFactory

  describe "subscriber lifecycle" do
    test "starts and subscribes to collection:diffs" do
      name = :"ingest_diffs_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestCollectionDiffs.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "diff handling" do
    test "records a craft when diff resolves to a clean single-card window" do
      card = create_card(rarity: "rare")
      Topics.subscribe(Topics.crafts_updates())

      name = :"ingest_diffs_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestCollectionDiffs.start_link(name: name)

      prev =
        create_collection_snapshot(
          reader_confidence: "walker",
          entries: [{card.arena_id, 0}],
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 4,
          wildcards_mythic: 5
        )

      next =
        create_collection_snapshot(
          reader_confidence: "walker",
          entries: [{card.arena_id, 1}],
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 3,
          wildcards_mythic: 5
        )

      diff = %Diff{from_snapshot_id: prev.id, to_snapshot_id: next.id}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      # Drain the GenServer mailbox.
      :sys.get_state(pid)

      assert Crafts.count() == 1
      assert_receive {:crafts_recorded, [_]}, 100

      GenServer.stop(pid)
    end

    test "no craft + no broadcast when wildcards unchanged" do
      card = create_card(rarity: "rare")
      Topics.subscribe(Topics.crafts_updates())

      name = :"ingest_diffs_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestCollectionDiffs.start_link(name: name)

      prev =
        create_collection_snapshot(
          reader_confidence: "walker",
          entries: [{card.arena_id, 0}],
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 4,
          wildcards_mythic: 5
        )

      next =
        create_collection_snapshot(
          reader_confidence: "walker",
          entries: [{card.arena_id, 1}],
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 4,
          wildcards_mythic: 5
        )

      diff = %Diff{from_snapshot_id: prev.id, to_snapshot_id: next.id}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      :sys.get_state(pid)

      assert Crafts.count() == 0
      refute_receive {:crafts_recorded, _}, 50

      GenServer.stop(pid)
    end

    test "tolerates missing to_snapshot (does not crash)" do
      name = :"ingest_diffs_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestCollectionDiffs.start_link(name: name)

      diff = %Diff{from_snapshot_id: nil, to_snapshot_id: 99_999_999}
      Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})

      :sys.get_state(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "end-to-end via Collection.save_snapshot/1 broadcasts a craft" do
      card = create_card(rarity: "rare")
      Topics.subscribe(Topics.crafts_updates())

      name = :"ingest_diffs_#{System.unique_integer([:positive])}"
      {:ok, pid} = IngestCollectionDiffs.start_link(name: name)

      # Save the baseline snapshot first (so prev exists for the next save).
      {:ok, _} =
        Collection.save_snapshot(%{
          entries: [{card.arena_id, 0}],
          card_count: 1,
          total_copies: 0,
          reader_confidence: "walker",
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 4,
          wildcards_mythic: 5,
          gold: 1000,
          gems: 0,
          vault_progress: 0.0,
          mtga_build_hint: "test"
        })

      :sys.get_state(pid)

      {:ok, _} =
        Collection.save_snapshot(%{
          entries: [{card.arena_id, 1}],
          card_count: 1,
          total_copies: 1,
          reader_confidence: "walker",
          wildcards_common: 10,
          wildcards_uncommon: 10,
          wildcards_rare: 3,
          wildcards_mythic: 5,
          gold: 1000,
          gems: 0,
          vault_progress: 0.0,
          mtga_build_hint: "test"
        })

      :sys.get_state(pid)

      assert Crafts.count() == 1
      assert_receive {:crafts_recorded, [%{arena_id: arena_id}]}, 200
      assert arena_id == card.arena_id

      GenServer.stop(pid)
    end
  end
end
