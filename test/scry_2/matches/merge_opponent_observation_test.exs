defmodule Scry2.Matches.MergeOpponentObservationTest do
  use Scry2.DataCase, async: false

  alias Scry2.LiveState.Snapshot
  alias Scry2.Matches.MergeOpponentObservation
  alias Scry2.Topics

  import Scry2.TestFactory

  describe "subscriber lifecycle" do
    test "starts and subscribes to live_match:final" do
      name = unique_name()
      {:ok, pid} = MergeOpponentObservation.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "snapshot handling" do
    test "merges snapshot fields into the match row when {:final, snapshot} arrives" do
      Topics.subscribe(Topics.matches_updates())
      name = unique_name()
      {:ok, pid} = MergeOpponentObservation.start_link(name: name)

      match = create_match(%{mtga_match_id: "M-500"})

      snapshot = %Snapshot{
        mtga_match_id: "M-500",
        opponent_screen_name: "MemoryObserved",
        opponent_ranking_class: 5,
        opponent_ranking_tier: 1
      }

      Topics.broadcast(Topics.live_match_final(), {:final, snapshot})

      :sys.get_state(pid)

      reloaded = Scry2.Repo.reload(match)
      assert reloaded.opponent_screen_name == "MemoryObserved"
      assert reloaded.opponent_rank == "Diamond 1"

      assert_receive {:match_updated, _}, 200

      GenServer.stop(pid)
    end

    test "ignores unrelated PubSub messages" do
      name = unique_name()
      {:ok, pid} = MergeOpponentObservation.start_link(name: name)

      send(pid, :something_unrelated)
      send(pid, {:tick, %{}})

      :sys.get_state(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  defp unique_name,
    do: :"merge_opponent_observation_#{System.unique_integer([:positive])}"
end
