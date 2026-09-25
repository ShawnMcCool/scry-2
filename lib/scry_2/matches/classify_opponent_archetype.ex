defmodule Scry2.Matches.ClassifyOpponentArchetype do
  @moduledoc """
  Classifies the opponent's archetype from their revealed cards once a
  match completes, via `Scry2.Matches.classify_opponent_archetype/1`.

  Subscribes to `domain:events` and reacts to `match_completed`. It used
  to react to the memory walker's final board snapshot, but revealed
  cards now come from the domain event log (ADR-047) — so the trigger is
  the match ending in that same log, not a memory observation.

  Match completion is the right moment: the revealed-cards projection has
  by then seen every disclosure in the match, so the classifier reads a
  complete card set rather than a partial one.

  Stateless.
  """

  use GenServer

  alias Scry2.Events.Match.MatchCompleted
  alias Scry2.Matches
  alias Scry2.Topics

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.domain_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:domain_event, _id, "match_completed", %MatchCompleted{} = event}, state) do
    case event.mtga_match_id do
      nil -> :ok
      mtga_match_id -> Matches.classify_opponent_archetype(mtga_match_id)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
