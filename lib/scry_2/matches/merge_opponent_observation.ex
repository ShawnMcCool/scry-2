defmodule Scry2.Matches.MergeOpponentObservation do
  @moduledoc """
  Subscribes to `Topics.live_match_final/0` and merges each
  `{:final, %Scry2.LiveState.Snapshot{}}` observation into the
  corresponding `matches_matches` row via
  `Scry2.Matches.merge_opponent_observation/1`.

  Stateless. Mirrors `Scry2.Economy.IngestMemoryGrants` and
  `Scry2.Crafts.IngestCollectionDiffs` — same memory-observation
  pattern, different projection table.
  """

  use GenServer

  alias Scry2.LiveState.Snapshot
  alias Scry2.Matches
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.live_match_final())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:final, %Snapshot{} = snapshot}, state) do
    Matches.merge_opponent_observation(snapshot)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}
end
