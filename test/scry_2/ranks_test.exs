defmodule Scry2.RanksTest do
  use Scry2.DataCase

  alias Scry2.Ranks
  alias Scry2.Topics

  describe "insert_snapshot!/1" do
    test "inserts a snapshot and broadcasts" do
      Topics.subscribe(Topics.ranks_updates())

      snapshot =
        Ranks.insert_snapshot!(%{
          constructed_class: "Gold",
          constructed_level: 1,
          constructed_step: 3,
          constructed_matches_won: 10,
          constructed_matches_lost: 5,
          limited_class: "Silver",
          limited_level: 2,
          limited_step: 4,
          limited_matches_won: 8,
          limited_matches_lost: 3,
          season_ordinal: 25,
          occurred_at: ~U[2026-04-08 12:00:00Z]
        })

      assert snapshot.constructed_class == "Gold"
      assert_receive {:rank_updated, _}
    end
  end

  describe "list_snapshots/1" do
    test "returns snapshots ordered by occurred_at ascending" do
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-08 14:00:00Z], constructed_class: "Gold"})

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-04-08 12:00:00Z],
        constructed_class: "Silver"
      })

      [first, second] = Ranks.list_snapshots()
      assert first.constructed_class == "Silver"
      assert second.constructed_class == "Gold"
    end

    test "filters by player_id" do
      player = Scry2.Players.find_or_create!("p1", "Player One")

      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-08 12:00:00Z], player_id: player.id})
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-08 13:00:00Z], player_id: nil})

      assert length(Ranks.list_snapshots(player_id: player.id)) == 1
    end
  end

  describe "latest_snapshot/1" do
    test "returns the most recent snapshot" do
      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-04-08 12:00:00Z],
        constructed_class: "Silver"
      })

      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-08 14:00:00Z], constructed_class: "Gold"})

      assert Ranks.latest_snapshot().constructed_class == "Gold"
    end

    test "returns nil when no snapshots exist" do
      assert Ranks.latest_snapshot() == nil
    end
  end

  describe "count/1" do
    test "returns the number of snapshots" do
      assert Ranks.count() == 0
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-08 12:00:00Z]})
      assert Ranks.count() == 1
    end
  end

  describe "list_seasons/1" do
    test "returns distinct season ordinals newest first" do
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-01-01 00:00:00Z], season_ordinal: 40})
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-02-01 00:00:00Z], season_ordinal: 41})
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-03-01 00:00:00Z], season_ordinal: 41})
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-04-01 00:00:00Z], season_ordinal: 42})

      assert Ranks.list_seasons() == [42, 41, 40]
    end

    test "excludes snapshots with nil season_ordinal" do
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-01-01 00:00:00Z], season_ordinal: nil})
      Ranks.insert_snapshot!(%{occurred_at: ~U[2026-02-01 00:00:00Z], season_ordinal: 41})

      assert Ranks.list_seasons() == [41]
    end

    test "filters by player_id" do
      player = Scry2.Players.find_or_create!("p2", "Player Two")

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-01-01 00:00:00Z],
        season_ordinal: 40,
        player_id: player.id
      })

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-02-01 00:00:00Z],
        season_ordinal: 41,
        player_id: nil
      })

      assert Ranks.list_seasons(player_id: player.id) == [40]
    end
  end

  describe "list_snapshots_for_season/1" do
    test "returns only snapshots for the given season, ordered by occurred_at ascending" do
      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-02-01 00:00:00Z],
        season_ordinal: 41,
        constructed_class: "Silver"
      })

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-01-01 00:00:00Z],
        season_ordinal: 41,
        constructed_class: "Bronze"
      })

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-03-01 00:00:00Z],
        season_ordinal: 42,
        constructed_class: "Gold"
      })

      snapshots = Ranks.list_snapshots_for_season(season: 41)

      assert length(snapshots) == 2
      assert [first, second] = snapshots
      assert first.constructed_class == "Bronze"
      assert second.constructed_class == "Silver"
    end

    test "returns empty list when no snapshots exist for the season" do
      assert Ranks.list_snapshots_for_season(season: 99) == []
    end
  end

  describe "latest_snapshot_for_season/1" do
    test "returns the most recent snapshot for the given season" do
      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-01-01 00:00:00Z],
        season_ordinal: 41,
        constructed_class: "Bronze"
      })

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-02-01 00:00:00Z],
        season_ordinal: 41,
        constructed_class: "Silver"
      })

      Ranks.insert_snapshot!(%{
        occurred_at: ~U[2026-03-01 00:00:00Z],
        season_ordinal: 42,
        constructed_class: "Gold"
      })

      latest = Ranks.latest_snapshot_for_season(season: 41)

      assert latest.constructed_class == "Silver"
    end

    test "returns nil when season has no snapshots" do
      assert Ranks.latest_snapshot_for_season(season: 99) == nil
    end
  end
end
