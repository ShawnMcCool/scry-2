defmodule Scry2.LiveStateFacadeTest do
  use Scry2.DataCase, async: false

  alias Phoenix.PubSub
  alias Scry2.LiveState
  alias Scry2.LiveState.Snapshot

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
end
