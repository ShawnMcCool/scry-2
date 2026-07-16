defmodule Scry2.Matches.ClassifyOpponentArchetype do
  @moduledoc """
  Subscribes to `Topics.live_match_board_final/0` and classifies the
  opponent's archetype from their revealed cards whenever a match's
  final board snapshot lands, via
  `Scry2.Matches.classify_opponent_archetype/1`.

  Stateless. Mirrors `Scry2.Matches.MergeOpponentObservation` — same
  memory-observation scaffold, different enrichment.
  """

  use Scry2.Events.MemoryObservationConsumer, topic: Scry2.Topics.live_match_board_final()

  alias Scry2.LiveState
  alias Scry2.LiveState.BoardSnapshot
  alias Scry2.Matches

  @impl true
  def handle_info({:final_board, %BoardSnapshot{} = board}, state) do
    case LiveState.match_id_for_board(board) do
      nil -> :ok
      mtga_match_id -> Matches.classify_opponent_archetype(mtga_match_id)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
