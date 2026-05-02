defmodule Scry2.CraftsTest do
  use Scry2.DataCase, async: false

  alias Scry2.Crafts
  alias Scry2.Crafts.Craft
  alias Scry2.Topics

  import Scry2.TestFactory

  # Build a snapshot pair where:
  #   - rare wildcards: 4 → 3
  #   - card #card_id (rare) goes 0 → 1
  # In the DB so they have ids that crafts can FK to.
  defp craft_pair(card_id) do
    prev =
      create_collection_snapshot(
        reader_confidence: "walker",
        entries: [{card_id, 0}],
        wildcards_common: 10,
        wildcards_uncommon: 10,
        wildcards_rare: 4,
        wildcards_mythic: 5
      )

    next =
      create_collection_snapshot(
        reader_confidence: "walker",
        entries: [{card_id, 1}],
        wildcards_common: 10,
        wildcards_uncommon: 10,
        wildcards_rare: 3,
        wildcards_mythic: 5
      )

    {prev, next}
  end

  describe "record_from_snapshot_pair/2" do
    test "persists a craft and broadcasts on crafts:updates when rule fires" do
      card = create_card(rarity: "rare")
      Topics.subscribe(Topics.crafts_updates())

      {prev, next} = craft_pair(card.arena_id)

      assert {:ok, [craft]} = Crafts.record_from_snapshot_pair(prev, next)
      assert craft.arena_id == card.arena_id
      assert craft.rarity == "rare"
      assert craft.quantity == 1
      assert craft.from_snapshot_id == prev.id
      assert craft.to_snapshot_id == next.id

      assert_receive {:crafts_recorded, [%Craft{arena_id: arena_id}]}, 100
      assert arena_id == card.arena_id
    end

    test "returns {:ok, []} and does not broadcast when no attribution" do
      card = create_card(rarity: "rare")
      Topics.subscribe(Topics.crafts_updates())

      # Same wildcard counts on both sides — no spend.
      prev =
        create_collection_snapshot(
          reader_confidence: "walker",
          entries: [{card.arena_id, 1}],
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

      assert {:ok, []} = Crafts.record_from_snapshot_pair(prev, next)
      refute_receive {:crafts_recorded, _}, 50
    end

    test "is idempotent: second call on same pair inserts nothing new" do
      card = create_card(rarity: "rare")
      {prev, next} = craft_pair(card.arena_id)

      assert {:ok, [_craft]} = Crafts.record_from_snapshot_pair(prev, next)
      assert Crafts.count() == 1

      assert {:ok, []} = Crafts.record_from_snapshot_pair(prev, next)
      assert Crafts.count() == 1
    end

    test "skips when card is not in cards_cards (unknown rarity)" do
      # Card not synthesized — rarity unknown — attribution can't fire.
      {prev, next} = craft_pair(999_999)

      assert {:ok, []} = Crafts.record_from_snapshot_pair(prev, next)
      assert Crafts.count() == 0
    end

    test "occurred_at_lower equals prev.snapshot_ts; occurred_at_upper equals next.snapshot_ts" do
      card = create_card(rarity: "rare")
      {prev, next} = craft_pair(card.arena_id)

      assert {:ok, [craft]} = Crafts.record_from_snapshot_pair(prev, next)
      assert DateTime.compare(craft.occurred_at_lower, prev.snapshot_ts) == :eq
      assert DateTime.compare(craft.occurred_at_upper, next.snapshot_ts) == :eq
    end
  end

  describe "list_recent/1" do
    test "returns crafts newest-first by occurred_at_upper" do
      card_a = create_card(rarity: "rare")
      card_b = create_card(rarity: "rare")

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      old = DateTime.add(now, -3600, :second)

      to_old = create_collection_snapshot(snapshot_ts: old, reader_confidence: "walker")
      to_new = create_collection_snapshot(snapshot_ts: now, reader_confidence: "walker")

      _old_craft =
        create_craft(
          arena_id: card_a.arena_id,
          to_snapshot_id: to_old.id,
          occurred_at_upper: old
        )

      _new_craft =
        create_craft(
          arena_id: card_b.arena_id,
          to_snapshot_id: to_new.id,
          occurred_at_upper: now
        )

      [first, second] = Crafts.list_recent(limit: 10)
      assert first.arena_id == card_b.arena_id
      assert second.arena_id == card_a.arena_id
    end

    test "respects :limit option" do
      card = create_card(rarity: "rare")

      for i <- 1..3 do
        snap = create_collection_snapshot(reader_confidence: "walker")
        create_craft(arena_id: card.arena_id + i, to_snapshot_id: snap.id)
      end

      assert length(Crafts.list_recent(limit: 2)) == 2
    end
  end

  describe "replay!/0" do
    test "iterates consecutive snapshot pairs and records crafts" do
      card = create_card(rarity: "rare")
      {_prev, _next} = craft_pair(card.arena_id)

      assert Crafts.count() == 0
      summary = Crafts.replay!()

      assert summary.processed == 2
      assert summary.recorded == 1
      assert Crafts.count() == 1
    end

    test "is idempotent — second call records nothing new" do
      card = create_card(rarity: "rare")
      {_prev, _next} = craft_pair(card.arena_id)

      _ = Crafts.replay!()
      assert Crafts.count() == 1

      summary = Crafts.replay!()
      assert summary.recorded == 0
      assert Crafts.count() == 1
    end
  end
end
