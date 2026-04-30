defmodule Scry2.CollectionTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection
  alias Scry2.Collection.Diff
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

    test "persists mtga_match_id and match_phase when both supplied" do
      result = %{
        entries: [{30_001, 1}],
        card_count: 1,
        total_copies: 1,
        reader_confidence: "fallback_scan",
        mtga_match_id: "match-tag-test",
        match_phase: "pre"
      }

      assert {:ok, snapshot} = Collection.save_snapshot(result)
      assert snapshot.mtga_match_id == "match-tag-test"
      assert snapshot.match_phase == "pre"
    end

    test "omits match_tag fields when mtga_match_id is absent" do
      result = %{
        entries: [{30_001, 1}],
        card_count: 1,
        total_copies: 1,
        reader_confidence: "fallback_scan"
      }

      assert {:ok, snapshot} = Collection.save_snapshot(result)
      assert snapshot.mtga_match_id == nil
      assert snapshot.match_phase == nil
    end

    test "creates a baseline diff (from_snapshot_id=nil) on the first snapshot" do
      Scry2.Topics.subscribe(Scry2.Topics.collection_diffs())

      assert {:ok, snapshot} =
               Collection.save_snapshot(%{
                 entries: [{30_001, 4}, {30_002, 1}],
                 card_count: 2,
                 total_copies: 5,
                 reader_confidence: "fallback_scan"
               })

      assert_receive {:diff_saved, %Diff{} = diff}
      assert diff.from_snapshot_id == nil
      assert diff.to_snapshot_id == snapshot.id
      assert diff.total_acquired == 5
      assert diff.total_removed == 0
      assert Diff.decode_counts(diff.cards_added_json) == %{30_001 => 4, 30_002 => 1}
      assert Diff.decode_counts(diff.cards_removed_json) == %{}
    end

    test "second snapshot diffs against the first" do
      {:ok, first} =
        Collection.save_snapshot(%{
          entries: [{30_001, 4}, {30_002, 2}],
          card_count: 2,
          total_copies: 6,
          reader_confidence: "fallback_scan"
        })

      Scry2.Topics.subscribe(Scry2.Topics.collection_diffs())

      {:ok, second} =
        Collection.save_snapshot(%{
          entries: [{30_001, 4}, {30_002, 1}, {30_003, 3}],
          card_count: 3,
          total_copies: 8,
          reader_confidence: "fallback_scan"
        })

      assert_receive {:diff_saved, %Diff{} = diff}
      assert diff.from_snapshot_id == first.id
      assert diff.to_snapshot_id == second.id
      assert Diff.decode_counts(diff.cards_added_json) == %{30_003 => 3}
      assert Diff.decode_counts(diff.cards_removed_json) == %{30_002 => 1}
      assert diff.total_acquired == 3
      assert diff.total_removed == 1
    end

    test "save_snapshot rolls back when the diff would violate uniqueness" do
      assert {:ok, _first} =
               Collection.save_snapshot(%{
                 entries: [{30_001, 1}],
                 card_count: 1,
                 total_copies: 1,
                 reader_confidence: "fallback_scan"
               })

      assert is_struct(Collection.latest_diff(), Diff)
    end
  end

  describe "latest_diff/0 and list_diffs/1" do
    test "returns nil when no diffs exist" do
      assert Collection.latest_diff() == nil
      assert Collection.list_diffs() == []
    end

    test "returns the most recent diff first" do
      {:ok, _} = save(entries: [{30_001, 1}])
      {:ok, _} = save(entries: [{30_001, 2}])
      {:ok, _} = save(entries: [{30_001, 3}])

      [latest, middle, _baseline] = Collection.list_diffs(limit: 3)

      assert latest.inserted_at >= middle.inserted_at
      assert Collection.latest_diff().id == latest.id
    end

    test "list_diffs/1 honors :limit" do
      for count <- 1..3 do
        {:ok, _} = save(entries: [{30_001, count}])
      end

      assert length(Collection.list_diffs(limit: 2)) == 2
    end
  end

  describe "diff_between/2" do
    test "computes a fresh diff between two existing snapshots" do
      a = TestFactory.create_collection_snapshot(entries: [{30_001, 1}])
      b = TestFactory.create_collection_snapshot(entries: [{30_001, 4}, {30_002, 1}])

      assert Collection.diff_between(a.id, b.id) == %{
               acquired: %{30_001 => 3, 30_002 => 1},
               removed: %{}
             }
    end

    test "returns nil when either snapshot is missing" do
      assert Collection.diff_between(999_998, 999_999) == nil
    end
  end

  describe "diagnostics queries" do
    test "count_snapshots/0 and count_diffs/0 are zero on an empty repo" do
      assert Collection.count_snapshots() == 0
      assert Collection.count_diffs() == 0
      assert Collection.count_empty_diffs() == 0
      assert Collection.top_diffs_by_acquired(5) == []
      assert Collection.reader_path_breakdown() == %{walker: 0, fallback_scan: 0}
    end

    test "count_snapshots and count_diffs grow with each save" do
      {:ok, _} = save(entries: [{30_001, 1}])
      assert Collection.count_snapshots() == 1
      assert Collection.count_diffs() == 1

      {:ok, _} = save(entries: [{30_001, 2}])
      assert Collection.count_snapshots() == 2
      assert Collection.count_diffs() == 2
    end

    test "count_empty_diffs counts diffs where neither side recorded a change" do
      {:ok, _} = save(entries: [{30_001, 1}])
      {:ok, _} = save(entries: [{30_001, 1}])
      {:ok, _} = save(entries: [{30_001, 2}])

      assert Collection.count_empty_diffs() == 1
    end

    test "top_diffs_by_acquired returns biggest acquisitions first" do
      {:ok, _} = save(entries: [{30_001, 1}])
      {:ok, _} = save(entries: [{30_001, 1}, {30_002, 4}])
      {:ok, _} = save(entries: [{30_001, 1}, {30_002, 4}, {30_003, 2}])

      [biggest, second | _] = Collection.top_diffs_by_acquired(3)
      assert biggest.total_acquired == 4
      assert second.total_acquired == 2
    end

    test "reader_path_breakdown groups by reader_confidence" do
      Collection.save_snapshot(%{
        entries: [{30_001, 1}],
        card_count: 1,
        total_copies: 1,
        reader_confidence: "walker"
      })

      Collection.save_snapshot(%{
        entries: [{30_001, 2}],
        card_count: 1,
        total_copies: 2,
        reader_confidence: "fallback_scan"
      })

      Collection.save_snapshot(%{
        entries: [{30_001, 3}],
        card_count: 1,
        total_copies: 3,
        reader_confidence: "fallback_scan"
      })

      assert Collection.reader_path_breakdown() == %{walker: 1, fallback_scan: 2}
    end
  end

  defp save(opts) do
    entries = Keyword.fetch!(opts, :entries)

    Collection.save_snapshot(%{
      entries: entries,
      card_count: length(entries),
      total_copies: Enum.reduce(entries, 0, fn {_, c}, acc -> acc + c end),
      reader_confidence: "fallback_scan"
    })
  end
end
