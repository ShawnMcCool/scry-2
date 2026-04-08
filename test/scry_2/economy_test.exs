defmodule Scry2.EconomyTest do
  use Scry2.DataCase

  alias Scry2.Economy
  alias Scry2.Topics

  describe "event entries" do
    test "upsert_event_entry!/1 inserts and broadcasts" do
      Topics.subscribe(Topics.economy_updates())

      entry =
        Economy.upsert_event_entry!(%{
          event_name: "PremierDraft_FDN_20260401",
          entry_currency_type: "Gems",
          entry_fee: 1500,
          joined_at: ~U[2026-04-08 12:00:00Z]
        })

      assert entry.event_name == "PremierDraft_FDN_20260401"
      assert entry.entry_fee == 1500
      assert_receive {:economy_updated, :event_entry}
    end

    test "enrich_with_reward!/3 updates the matching entry" do
      Economy.upsert_event_entry!(%{
        player_id: 1,
        event_name: "PremierDraft_FDN_20260401",
        entry_fee: 1500,
        joined_at: ~U[2026-04-08 12:00:00Z]
      })

      Economy.enrich_with_reward!(1, "PremierDraft_FDN_20260401", %{
        final_wins: 5,
        final_losses: 3,
        gems_awarded: 650,
        gold_awarded: 0,
        claimed_at: ~U[2026-04-08 14:00:00Z]
      })

      [entry] = Economy.list_event_entries()
      assert entry.final_wins == 5
      assert entry.gems_awarded == 650
    end

    test "list_event_entries/1 returns newest first" do
      Economy.upsert_event_entry!(%{
        event_name: "A",
        joined_at: ~U[2026-04-08 10:00:00Z]
      })

      Economy.upsert_event_entry!(%{
        event_name: "B",
        joined_at: ~U[2026-04-08 14:00:00Z]
      })

      [first, second] = Economy.list_event_entries()
      assert first.event_name == "B"
      assert second.event_name == "A"
    end
  end

  describe "inventory snapshots" do
    test "insert_inventory_snapshot!/1 inserts and broadcasts" do
      Topics.subscribe(Topics.economy_updates())

      snapshot =
        Economy.insert_inventory_snapshot!(%{
          gold: 5000,
          gems: 1200,
          wildcards_rare: 3,
          occurred_at: ~U[2026-04-08 12:00:00Z]
        })

      assert snapshot.gold == 5000
      assert_receive {:economy_updated, :inventory}
    end

    test "latest_inventory/1 returns the most recent" do
      Economy.insert_inventory_snapshot!(%{
        gold: 1000,
        occurred_at: ~U[2026-04-08 10:00:00Z]
      })

      Economy.insert_inventory_snapshot!(%{
        gold: 5000,
        occurred_at: ~U[2026-04-08 14:00:00Z]
      })

      assert Economy.latest_inventory().gold == 5000
    end
  end

  describe "transactions" do
    test "insert_transaction!/1 inserts and broadcasts" do
      Topics.subscribe(Topics.economy_updates())

      transaction =
        Economy.insert_transaction!(%{
          source: "EventJoin",
          gold_delta: -500,
          gold_balance: 4500,
          occurred_at: ~U[2026-04-08 12:00:00Z]
        })

      assert transaction.gold_delta == -500
      assert_receive {:economy_updated, :transaction}
    end

    test "list_transactions/1 returns newest first with limit" do
      for i <- 1..5 do
        Economy.insert_transaction!(%{
          source: "Event#{i}",
          occurred_at: DateTime.add(~U[2026-04-08 12:00:00Z], i, :hour)
        })
      end

      results = Economy.list_transactions(limit: 3)
      assert length(results) == 3
      assert hd(results).source == "Event5"
    end
  end
end
