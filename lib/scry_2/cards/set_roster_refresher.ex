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
  rescue
    # Tests broadcast `cards_refreshed` from synthesize integration tests; the
    # GenServer runs outside the test's sandbox, so the refresh query has no
    # ownership and raises `DBConnection.OwnershipError`. Production calls
    # always have ownership (via the Oban worker / supervisor tree), so the
    # rescue is a no-op outside of test harnesses.
    DBConnection.OwnershipError -> {:noreply, state}
  catch
    # Same test-harness race, other timing: the sandbox owner exits while
    # the refresh query is in flight and DBConnection exits the client
    # instead of raising. Anything that is not that race is re-raised —
    # this must not become a blanket exit swallower.
    :exit, reason ->
      if sandbox_teardown?(reason), do: {:noreply, state}, else: exit(reason)
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The exit reason arrives in two shapes depending on whether the client
  # was inside a checkout call when the owner went away:
  #
  #     {:shutdown, %DBConnection.ConnectionError{}}
  #     {{:shutdown, %DBConnection.ConnectionError{}}, {Mod, :fun, args}}
  #
  # The earlier clause matched only the first, so a mid-checkout teardown
  # still killed this GenServer and intermittently failed `mix precommit`.
  defp sandbox_teardown?({_reason, %DBConnection.ConnectionError{}}), do: true
  defp sandbox_teardown?({{_reason, %DBConnection.ConnectionError{}}, _mfa}), do: true
  defp sandbox_teardown?(_other), do: false
end
