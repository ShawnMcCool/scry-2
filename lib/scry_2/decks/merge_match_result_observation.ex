defmodule Scry2.Decks.MergeMatchResultObservation do
  @moduledoc """
  Subscribes to `Topics.live_match_final/0` and merges each
  `{:final, %Scry2.LiveState.Snapshot{}}` observation into the
  corresponding `decks_match_results` row via
  `Scry2.Decks.merge_match_result_observation/1`.

  Stateless. Sibling of `Scry2.Matches.MergeOpponentObservation` —
  same broadcast, different projection table.
  """

  use GenServer

  alias Scry2.Decks
  alias Scry2.LiveState.Snapshot
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
    Decks.merge_match_result_observation(snapshot)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}
end
