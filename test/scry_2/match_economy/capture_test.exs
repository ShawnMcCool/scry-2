defmodule Scry2.MatchEconomy.CaptureTest do
  use Scry2.DataCase, async: false
  import Scry2.TestFactory

  alias Scry2.Collection.Snapshot
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.MatchEconomy
  alias Scry2.MatchEconomy.Capture
  alias Scry2.MtgaMemory.TestBackend
  alias Scry2.Repo

  # Enough cards with varied counts to pass plausible_count_distribution? (< 95% dominant).
  @base_cards [{70_012, 1}, {82_456, 4}, {91_234, 2}, {44_321, 3}, {30_001, 1}]

  @walker_snap_pre %{
    cards: @base_cards,
    wildcards: %{common: 10, uncommon: 5, rare: 2, mythic: 1},
    gold: 1000,
    gems: 50,
    vault_progress: 0.20,
    build_hint: "test-build",
    reader_version: "scry2-walker-test"
  }

  @walker_snap_post %{
    cards: @base_cards,
    wildcards: %{common: 11, uncommon: 5, rare: 2, mythic: 1},
    gold: 1250,
    gems: 50,
    vault_progress: 0.25,
    build_hint: "test-build",
    reader_version: "scry2-walker-test"
  }

  defp walker_fixture(walker_snap) do
    %{
      processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
      maps: [
        %{start: 0x100, end_addr: 0x200, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
        %{start: 0x300, end_addr: 0x400, perms: "r-xp", path: "UnityPlayer.dll"}
      ],
      walker_snapshot: walker_snap
    }
  end

  describe "handle_match_created/1" do
    setup do
      TestBackend.set_fixture(walker_fixture(@walker_snap_pre))
      on_exit(&TestBackend.clear_fixture/0)
      :ok
    end

    test "creates a tagged pre-snapshot and an incomplete summary" do
      occurred_at = ~U[2026-04-30 10:00:00.000000Z]

      Capture.handle_match_created(%MatchCreated{
        mtga_match_id: "m-pre",
        occurred_at: occurred_at
      })

      summary = MatchEconomy.get_summary("m-pre")
      assert summary != nil
      assert summary.reconciliation_state == "incomplete"
      assert summary.pre_snapshot_id != nil
      assert summary.started_at == occurred_at

      snapshot = Repo.get(Snapshot, summary.pre_snapshot_id)
      assert snapshot.mtga_match_id == "m-pre"
      assert snapshot.match_phase == "pre"
      assert snapshot.gold == 1000
      assert snapshot.wildcards_common == 10
    end

    test "summary has nil post_snapshot_id after MatchCreated" do
      Capture.handle_match_created(%MatchCreated{
        mtga_match_id: "m-no-post",
        occurred_at: ~U[2026-04-30 10:00:00.000000Z]
      })

      summary = MatchEconomy.get_summary("m-no-post")
      assert summary.post_snapshot_id == nil
    end
  end

  describe "handle_match_completed/1" do
    setup do
      TestBackend.set_fixture(walker_fixture(@walker_snap_post))
      on_exit(&TestBackend.clear_fixture/0)
      :ok
    end

    test "completes the summary with memory deltas + log reconciliation" do
      pre_snapshot =
        create_collection_snapshot(
          mtga_match_id: "m-end",
          match_phase: "pre",
          entries: [{30_001, 1}],
          wildcards_common: 10,
          wildcards_uncommon: 5,
          wildcards_rare: 2,
          wildcards_mythic: 1,
          gold: 1000,
          gems: 50,
          vault_progress: 0.20
        )

      create_match_economy_summary(
        mtga_match_id: "m-end",
        started_at: ~U[2026-04-30 10:00:00.000000Z],
        pre_snapshot_id: pre_snapshot.id,
        reconciliation_state: "incomplete"
      )

      create_economy_transaction(
        occurred_at: ~U[2026-04-30 10:30:00Z],
        gold_delta: 250,
        gems_delta: 0
      )

      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 09:50:00Z],
        wildcards_common: 10,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      create_inventory_snapshot(
        occurred_at: ~U[2026-04-30 10:55:00Z],
        wildcards_common: 11,
        wildcards_uncommon: 5,
        wildcards_rare: 2,
        wildcards_mythic: 1
      )

      Capture.handle_match_completed(%MatchCompleted{
        mtga_match_id: "m-end",
        occurred_at: ~U[2026-04-30 11:00:00.000000Z],
        won: true,
        num_games: 2
      })

      summary = MatchEconomy.get_summary("m-end")
      assert summary.reconciliation_state == "complete"
      assert summary.memory_gold_delta == 250
      assert summary.memory_wildcards_common_delta == 1
      assert summary.log_gold_delta == 250
      assert summary.log_wildcards_common_delta == 1
      assert summary.diff_gold == 0
      assert summary.diff_wildcards_common == 0
    end

    test "creates a post-snapshot tagged with match_phase=post" do
      pre_snapshot =
        create_collection_snapshot(
          mtga_match_id: "m-post-tag",
          match_phase: "pre",
          entries: [{30_001, 1}],
          gold: 1000,
          gems: 50,
          wildcards_common: 10,
          wildcards_uncommon: 5,
          wildcards_rare: 2,
          wildcards_mythic: 1,
          vault_progress: 0.20
        )

      create_match_economy_summary(
        mtga_match_id: "m-post-tag",
        started_at: ~U[2026-04-30 10:00:00.000000Z],
        pre_snapshot_id: pre_snapshot.id,
        reconciliation_state: "incomplete"
      )

      Capture.handle_match_completed(%MatchCompleted{
        mtga_match_id: "m-post-tag",
        occurred_at: ~U[2026-04-30 11:00:00.000000Z],
        won: true,
        num_games: 1
      })

      summary = MatchEconomy.get_summary("m-post-tag")
      assert summary.post_snapshot_id != nil

      post_snap = Repo.get(Snapshot, summary.post_snapshot_id)
      assert post_snap.match_phase == "post"
      assert post_snap.mtga_match_id == "m-post-tag"
    end
  end
end
