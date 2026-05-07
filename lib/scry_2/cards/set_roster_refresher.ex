defmodule Scry2.Cards.SetRosterRefresher do
  @moduledoc """
  Keeps the `Scry2.Cards.SetRoster` cache fresh.

  Subscribes to `Scry2.Topics.cards_updates/0` and rebuilds the
  `:persistent_term`-backed roster map whenever the synthesised
  `cards_cards` table changes (broadcast as `{:cards_refreshed, _}`).
  Other messages on the topic are ignored.
  """

  use GenServer

  alias Scry2.Cards.SetRoster
  alias Scry2.Topics

  require Scry2.Log, as: Log

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.cards_updates())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cards_refreshed, _}, state) do
    rosters = SetRoster.refresh()
    Log.info(:importer, "set roster cache refreshed (#{map_size(rosters)} sets)")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
