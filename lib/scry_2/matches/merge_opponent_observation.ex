defmodule Scry2.Matches.MergeOpponentObservation do
  @moduledoc """
  Subscribes to `Topics.live_match_final/0` and merges each
  `{:final, %Scry2.LiveState.Snapshot{}}` observation into the
  corresponding `matches_matches` row via
  `Scry2.Matches.merge_opponent_observation/1`.

  Stateless. Mirrors `Scry2.Decks.MergeMatchResultObservation`,
  `Scry2.Economy.IngestMemoryGrants`, and
  `Scry2.Crafts.IngestCollectionDiffs` — same memory-observation
  scaffold, different projection table.
  """

  use Scry2.Events.MemoryObservationConsumer, topic: Scry2.Topics.live_match_final()

  alias Scry2.LiveState.Snapshot
  alias Scry2.Matches

  @impl true
  def handle_info({:final, %Snapshot{} = snapshot}, state) do
    Matches.merge_opponent_observation(snapshot)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
