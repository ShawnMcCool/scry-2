defmodule Scry2.Decks.MergeMatchResultObservationTest do
  use Scry2.DataCase, async: false

  alias Scry2.Decks.MergeMatchResultObservation
  alias Scry2.LiveState.Snapshot
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "subscriber lifecycle" do
    test "starts and subscribes to live_match:final" do
      name = unique_name()
      {:ok, pid} = MergeMatchResultObservation.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "snapshot handling" do
    test "merges snapshot fields into the match_result row" do
      result =
        TestFactory.create_deck_match_result(%{
          deck: TestFactory.create_deck(%{mtga_deck_id: "D-500"}),
          mtga_match_id: "M-500"
        })

      Topics.subscribe(Topics.decks_updates())

      name = unique_name()
      {:ok, pid} = MergeMatchResultObservation.start_link(name: name)

      snapshot = %Snapshot{
        mtga_match_id: "M-500",
        opponent_screen_name: "MemoryObserved",
        opponent_ranking_class: 5,
        opponent_ranking_tier: 1
      }

      Topics.broadcast(Topics.live_match_final(), {:final, snapshot})

      :sys.get_state(pid)

      reloaded = Scry2.Repo.reload(result)
      assert reloaded.opponent_screen_name == "MemoryObserved"
      assert reloaded.opponent_rank == "Diamond 1"

      assert_receive {:deck_updated, _}, 200

      GenServer.stop(pid)
    end

    test "ignores unrelated PubSub messages" do
      name = unique_name()
      {:ok, pid} = MergeMatchResultObservation.start_link(name: name)

      send(pid, :unrelated)
      send(pid, {:tick, %{}})

      :sys.get_state(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  defp unique_name,
    do: :"merge_match_result_observation_#{System.unique_integer([:positive])}"
end
