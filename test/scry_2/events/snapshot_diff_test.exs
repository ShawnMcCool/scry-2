defmodule Scry2.Events.SnapshotDiffTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2.Events.SnapshotDiff

  # ── DeckInventory ─────────────────────────────────────────────────────────

  describe "changed?/2 DeckInventory" do
    test "returns :unchanged when deck IDs, names, and formats are all identical" do
      event = build_deck_inventory()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_deck_inventory()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when a new deck is added" do
      event =
        build_deck_inventory(
          decks: [%{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"}]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"},
            %{deck_id: "deck-ghi-789", name: "New Deck", format: "Historic"}
          ]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when a deck is renamed (same deck_ids)" do
      event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "Old Name", format: "Standard"}
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      renamed_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "New Name", format: "Standard"}
          ]
        )

      assert {:changed, new_key} = SnapshotDiff.changed?(renamed_event, key)
      assert new_key != key
    end

    test "returns {:changed, key} when a deck's format changes (same deck_ids)" do
      event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "My Deck", format: "Historic"}
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      reformatted_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "My Deck", format: "Explorer"}
          ]
        )

      assert {:changed, new_key} = SnapshotDiff.changed?(reformatted_event, key)
      assert new_key != key
    end

    test "returns {:changed, key} when a deck's name transitions nil→value" do
      event =
        build_deck_inventory(decks: [%{deck_id: "deck-abc-123", name: nil, format: "Standard"}])

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      named_event =
        build_deck_inventory(
          decks: [%{deck_id: "deck-abc-123", name: "Now Named", format: "Standard"}]
        )

      assert {:changed, new_key} = SnapshotDiff.changed?(named_event, key)
      assert new_key != key
    end

    test "deck order does not matter — same ids in different order is :unchanged" do
      event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-abc-123", name: "Deck A", format: "Standard"},
            %{deck_id: "deck-def-456", name: "Deck B", format: "Limited"}
          ]
        )

      {:changed, key} = SnapshotDiff.changed?(event, nil)

      reordered_event =
        build_deck_inventory(
          decks: [
            %{deck_id: "deck-def-456", name: "Deck B", format: "Limited"},
            %{deck_id: "deck-abc-123", name: "Deck A", format: "Standard"}
          ]
        )

      assert SnapshotDiff.changed?(reordered_event, key) == :unchanged
    end

    test "nil→value transition on deck_id (empty to populated)" do
      event = build_deck_inventory(decks: [])
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event =
        build_deck_inventory(
          decks: [%{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"}]
        )

      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── InventorySnapshot ─────────────────────────────────────────────────────

  describe "changed?/2 InventorySnapshot" do
    test "returns :unchanged when all economy fields are identical" do
      event = build_inventory_snapshot()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_inventory_snapshot()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when gold changes" do
      event = build_inventory_snapshot(gold: 5000)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(gold: 6000)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when boosters change" do
      event = build_inventory_snapshot(boosters: [%{set_code: "FDN", count: 3}])
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(boosters: [%{set_code: "FDN", count: 4}])
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on gems" do
      event = build_inventory_snapshot(gems: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_snapshot(gems: 1200)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end

  # ── InventoryUpdated ──────────────────────────────────────────────────────

  describe "changed?/2 InventoryUpdated" do
    test "returns :unchanged when all economy fields are identical" do
      event = build_inventory_updated()
      {:changed, key} = SnapshotDiff.changed?(event, nil)
      assert SnapshotDiff.changed?(event, key) == :unchanged
    end

    test "returns {:changed, key} when previous_key is nil (first sight)" do
      event = build_inventory_updated()
      assert {:changed, _key} = SnapshotDiff.changed?(event, nil)
    end

    test "returns {:changed, key} when wildcards_rare changes" do
      event = build_inventory_updated(wildcards_rare: 6)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(wildcards_rare: 7)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "returns {:changed, key} when vault_progress changes" do
      event = build_inventory_updated(vault_progress: 42.5)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(vault_progress: 55.0)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end

    test "nil→value transition on draft_tokens" do
      event = build_inventory_updated(draft_tokens: nil)
      {:changed, key} = SnapshotDiff.changed?(event, nil)

      updated_event = build_inventory_updated(draft_tokens: 1)
      assert {:changed, _new_key} = SnapshotDiff.changed?(updated_event, key)
    end
  end
end
