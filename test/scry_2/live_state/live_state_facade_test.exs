defmodule Scry2.LiveStateFacadeTest do
  use Scry2.DataCase, async: false

  alias Phoenix.PubSub
  alias Scry2.LiveState
  alias Scry2.LiveState.{BoardSnapshot, RevealedCard, Snapshot}
  alias Scry2.Topics

  describe "record_final/2" do
    test "inserts a new snapshot when none exists" do
      attrs = %{
        reader_version: "0.0.1",
        opponent_screen_name: "Lagun4",
        opponent_ranking_class: 5,
        opponent_ranking_tier: 4
      }

      assert {:ok, %Snapshot{} = snapshot} = LiveState.record_final("match-1", attrs)
      assert snapshot.mtga_match_id == "match-1"
      assert snapshot.opponent_screen_name == "Lagun4"
      assert snapshot.opponent_ranking_class == 5
    end

    test "upserts when a snapshot already exists for the same match id" do
      first_attrs = %{reader_version: "0.0.1", opponent_screen_name: "Lagun4"}
      {:ok, %Snapshot{id: id}} = LiveState.record_final("match-2", first_attrs)

      second_attrs = %{reader_version: "0.0.1", opponent_screen_name: "Lagun4 Updated"}
      {:ok, %Snapshot{id: ^id} = updated} = LiveState.record_final("match-2", second_attrs)

      assert updated.opponent_screen_name == "Lagun4 Updated"
      assert Repo.aggregate(Snapshot, :count) == 1
    end

    test "broadcasts on live_match:final" do
      :ok = PubSub.subscribe(Scry2.PubSub, LiveState.final_topic())

      {:ok, %Snapshot{} = snapshot} =
        LiveState.record_final("match-3", %{reader_version: "0.0.1"})

      assert_receive {:final, ^snapshot}, 100
    end
  end

  describe "get_by_match_id/1" do
    test "returns the row for an existing match id" do
      {:ok, inserted} = LiveState.record_final("match-4", %{reader_version: "0.0.1"})

      assert %Snapshot{id: id} = LiveState.get_by_match_id("match-4")
      assert id == inserted.id
    end

    test "returns nil for an unknown match id" do
      assert LiveState.get_by_match_id("nonexistent") == nil
    end
  end

  describe "broadcast_tick/1" do
    test "publishes :tick on live_match:updates" do
      :ok = PubSub.subscribe(Scry2.PubSub, LiveState.updates_topic())

      payload = %{mtga_match_id: "live-1", local: %{screen_name: "Me"}}
      :ok = LiveState.broadcast_tick(payload)

      assert_receive {:tick, ^payload}, 100
    end
  end

  describe "record_final_board/2" do
    setup do
      {:ok, snapshot} = LiveState.record_final("board-test", %{reader_version: "0.0.1"})
      %{parent: snapshot}
    end

    test "inserts the board snapshot + revealed-card rows in one transaction", %{parent: parent} do
      attrs = %{
        reader_version: "0.0.1",
        zones: [
          %{seat_id: 1, zone_id: 4, arena_ids: [101, 102]},
          %{seat_id: 2, zone_id: 4, arena_ids: [201]}
        ]
      }

      assert {:ok, %BoardSnapshot{} = board} =
               LiveState.record_final_board("board-test", attrs)

      assert board.live_state_snapshot_id == parent.id
      assert board.reader_version == "0.0.1"

      cards = LiveState.get_revealed_cards_by_match_id("board-test")
      assert length(cards) == 3

      [first | _] = cards
      assert %RevealedCard{seat_id: 1, zone_id: 4, arena_id: 101, position: 0} = first
    end

    test "returns parent_snapshot_missing when no Chain-1 snapshot exists" do
      attrs = %{reader_version: "0.0.1", zones: []}

      assert {:error, :parent_snapshot_missing} =
               LiveState.record_final_board("never-existed", attrs)
    end

    test "broadcasts {:final_board, board} on live_match:board_final" do
      :ok = Topics.subscribe(Topics.live_match_board_final())

      attrs = %{
        reader_version: "0.0.1",
        zones: [%{seat_id: 1, zone_id: 4, arena_ids: [99]}]
      }

      {:ok, %BoardSnapshot{} = board} = LiveState.record_final_board("board-test", attrs)
      assert_receive {:final_board, ^board}, 100
    end

    test "rejects a duplicate board snapshot for the same parent" do
      attrs = %{reader_version: "0.0.1", zones: []}
      {:ok, _} = LiveState.record_final_board("board-test", attrs)

      assert {:error, %Ecto.Changeset{}} = LiveState.record_final_board("board-test", attrs)
    end

    test "handles empty zones list cleanly" do
      attrs = %{reader_version: "0.0.1", zones: []}
      assert {:ok, %BoardSnapshot{}} = LiveState.record_final_board("board-test", attrs)
      assert LiveState.get_revealed_cards_by_match_id("board-test") == []
    end
  end

  describe "get_board_by_match_id/1" do
    test "returns the snapshot via the parent join" do
      {:ok, _} = LiveState.record_final("board-fetch", %{reader_version: "0.0.1"})

      {:ok, %BoardSnapshot{id: id}} =
        LiveState.record_final_board("board-fetch", %{
          reader_version: "0.0.1",
          zones: [%{seat_id: 1, zone_id: 4, arena_ids: [1]}]
        })

      assert %BoardSnapshot{id: ^id} = LiveState.get_board_by_match_id("board-fetch")
    end

    test "returns nil when no board snapshot exists" do
      assert LiveState.get_board_by_match_id("nope") == nil
    end
  end

  describe "get_revealed_cards_by_match_id/1" do
    test "orders rows by (seat_id, zone_id, position)" do
      {:ok, _} = LiveState.record_final("ordering", %{reader_version: "0.0.1"})

      attrs = %{
        reader_version: "0.0.1",
        zones: [
          %{seat_id: 2, zone_id: 4, arena_ids: [50, 60]},
          %{seat_id: 1, zone_id: 4, arena_ids: [10, 20, 30]}
        ]
      }

      {:ok, _} = LiveState.record_final_board("ordering", attrs)

      arena_ids = LiveState.get_revealed_cards_by_match_id("ordering") |> Enum.map(& &1.arena_id)
      # Seat 1 first (lower seat_id), then seat 2; within each seat,
      # arena_ids in storage order via position.
      assert arena_ids == [10, 20, 30, 50, 60]
    end

    test "returns [] for an unknown match" do
      assert LiveState.get_revealed_cards_by_match_id("nope") == []
    end
  end
end
