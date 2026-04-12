defmodule Scry2.Economy.EconomyProjection do
  @moduledoc """
  Projects economy domain events into the `economy_*` read models.

  ## Claimed domain events

    * `"event_joined"` → seed event entry with cost
    * `"event_reward_claimed"` → enrich event entry with prizes
    * `"inventory_updated"` → insert inventory balance snapshot
    * `"inventory_changed"` → insert transaction delta
  """
  use Scry2.Events.Projector,
    claimed_slugs: ~w(event_joined event_reward_claimed inventory_updated inventory_changed),
    projection_tables: [
      Scry2.Economy.Transaction,
      Scry2.Economy.InventorySnapshot,
      Scry2.Economy.EventEntry
    ]

  alias Scry2.Economy
  alias Scry2.Events.Economy.{InventoryChanged, InventoryUpdated}
  alias Scry2.Events.Event.{EventJoined, EventRewardClaimed}

  defp project(%EventJoined{entry_fee: fee} = event) when is_integer(fee) and fee > 0 do
    Economy.upsert_event_entry!(%{
      player_id: event.player_id,
      event_name: event.event_name,
      course_id: event.course_id,
      entry_currency_type: event.entry_currency_type,
      entry_fee: event.entry_fee,
      joined_at: event.occurred_at
    })

    Log.info(:ingester, "projected EventJoined event=#{event.event_name}")
    :ok
  end

  defp project(%EventJoined{}), do: :ok

  defp project(%EventRewardClaimed{} = event) do
    Economy.enrich_with_reward!(event.player_id, event.event_name, %{
      final_wins: event.final_wins,
      final_losses: event.final_losses,
      gems_awarded: event.gems_awarded,
      gold_awarded: event.gold_awarded,
      boosters_awarded: if(event.boosters_awarded, do: %{"packs" => event.boosters_awarded}),
      claimed_at: event.occurred_at
    })

    Log.info(:ingester, "projected EventRewardClaimed event=#{event.event_name}")
    :ok
  end

  defp project(%InventoryUpdated{} = event) do
    Economy.insert_inventory_snapshot!(%{
      player_id: event.player_id,
      gold: event.gold,
      gems: event.gems,
      wildcards_common: event.wildcards_common,
      wildcards_uncommon: event.wildcards_uncommon,
      wildcards_rare: event.wildcards_rare,
      wildcards_mythic: event.wildcards_mythic,
      vault_progress: event.vault_progress,
      occurred_at: event.occurred_at
    })

    Log.info(:ingester, "projected InventoryUpdated")
    :ok
  end

  defp project(%InventoryChanged{} = event) do
    Economy.insert_transaction!(%{
      player_id: event.player_id,
      source: event.source,
      source_id: event.source_id,
      gold_delta: event.gold_delta,
      gems_delta: event.gems_delta,
      boosters: if(event.boosters, do: %{"packs" => event.boosters}),
      gold_balance: event.gold_balance,
      gems_balance: event.gems_balance,
      occurred_at: event.occurred_at
    })

    Log.info(:ingester, "projected InventoryChanged source=#{event.source}")
    :ok
  end

  defp project(_event), do: :ok
end
