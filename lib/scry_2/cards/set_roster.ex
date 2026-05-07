defmodule Scry2.Cards.SetRoster do
  @moduledoc """
  The canonical card list of a set, grouped by rarity.

  A `SetRoster` answers the question "what could I own from this set?". It
  is the reference point completion-of-set ratios are measured against:
  intersect a `SetRoster` with the user's `Holding`s and the result is a
  `Scry2.Collection.Completion`.

  Rosters are derived from `cards_cards` (the synthesised read model) — they
  are not a separate persistence concern. Non-booster rows are excluded so
  Alchemy duplicates, basics, and tokens do not skew completion percentages.

  ## Cache

  `compute/0` always queries the database. `all/0` returns the full
  `%{set_id => SetRoster.t()}` map from a `:persistent_term` cache; it
  computes-and-caches on first read. `Scry2.Cards.SetRosterRefresher`
  rebuilds the cache when `Topics.cards_updates/0` broadcasts a
  `{:cards_refreshed, _}` message.
  """

  alias Scry2.Cards.{Card, Set}
  alias Scry2.Repo

  import Ecto.Query

  @enforce_keys [:set, :totals]
  defstruct [:set, :totals]

  @type rarity :: String.t()

  @type t :: %__MODULE__{
          set: Set.t(),
          totals: %{rarity() => non_neg_integer()}
        }

  @cache_key {__MODULE__, :v1}

  @doc """
  Computes a fresh `%{set_id => SetRoster.t()}` map directly from the
  database. Always hits the DB.
  """
  @spec compute() :: %{integer() => t()}
  def compute do
    sets_by_id =
      Set
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    totals_by_set =
      Card
      |> where([c], c.is_booster == true)
      |> where([c], not is_nil(c.set_id))
      |> where([c], not is_nil(c.rarity))
      |> group_by([c], [c.set_id, c.rarity])
      |> select([c], {c.set_id, c.rarity, count(c.arena_id)})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {set_id, rarity, count}, acc ->
        Map.update(acc, set_id, %{rarity => count}, &Map.put(&1, rarity, count))
      end)

    for {set_id, totals} <- totals_by_set,
        set = Map.get(sets_by_id, set_id),
        not is_nil(set),
        into: %{} do
      {set_id, %__MODULE__{set: set, totals: totals}}
    end
  end

  @doc """
  Returns the cached `%{set_id => SetRoster.t()}` map, computing on first
  access.
  """
  @spec all() :: %{integer() => t()}
  def all do
    case :persistent_term.get(@cache_key, :miss) do
      :miss -> refresh()
      cached -> cached
    end
  end

  @doc """
  Recomputes the cache from the database and returns the new map.
  """
  @spec refresh() :: %{integer() => t()}
  def refresh do
    rosters = compute()
    :persistent_term.put(@cache_key, rosters)
    rosters
  end

  @doc "Returns the roster for one set, or nil."
  @spec for(integer()) :: t() | nil
  def for(set_id) when is_integer(set_id) do
    Map.get(all(), set_id)
  end

  @doc "Returns the `%Set{}` metadata for a set id without re-querying, or nil."
  @spec label(integer()) :: Set.t() | nil
  def label(set_id) when is_integer(set_id) do
    case Map.get(all(), set_id) do
      %__MODULE__{set: set} -> set
      nil -> nil
    end
  end
end
