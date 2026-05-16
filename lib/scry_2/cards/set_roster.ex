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

  @enforce_keys [:set, :totals, :names_by_rarity]
  defstruct [:set, :totals, :names_by_rarity]

  @type rarity :: String.t()

  @type t :: %__MODULE__{
          set: Set.t(),
          totals: %{rarity() => non_neg_integer()},
          names_by_rarity: %{rarity() => MapSet.t(String.t())}
        }

  @cache_key {__MODULE__, :v1}

  # Rarities counted toward set completion: every rarity that drops in
  # a booster pack. `"token"` and `"basic"` never drop in boosters and
  # are excluded by definition.
  @booster_rarities ~w(common uncommon rare mythic)

  @doc """
  Computes a fresh `%{set_id => SetRoster.t()}` map directly from the
  database. Always hits the DB.

  ## Filter

  A card counts toward set completion when its rarity is one of
  `common | uncommon | rare | mythic` (tokens and basics excluded by
  definition) AND either:

    * Scryfall has tagged the card with `booster = true`, OR
    * Scryfall has not tagged ANY card in this set with `booster = true`
      (the new-set lag — Scryfall's bulk data leaves `booster` empty
      for weeks after a Standard release; same lag shape as the
      `arena_id` case fixed in ADR-038)

  Without the lag fallback, a brand-new set like Secrets of Strixhaven
  would show only 12 cards in its roster instead of ~340, breaking the
  Collection page's completion percentages on the very sets the user
  is actively drafting.
  """
  @spec compute() :: %{integer() => t()}
  def compute do
    sets_by_id =
      Set
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    sets_in_scryfall_lag = sets_with_no_booster_signal()

    # Select card *names* per (set, rarity) and roll them into MapSets
    # so alternate-art printings collapse — `totals` then counts unique
    # cards the player can build, not unique arena_ids.
    names_by_set =
      Card
      |> where([c], not is_nil(c.set_id))
      |> where([c], c.rarity in @booster_rarities)
      |> where(
        [c],
        c.is_booster == true or c.set_id in ^MapSet.to_list(sets_in_scryfall_lag)
      )
      |> select([c], {c.set_id, c.rarity, c.name})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {set_id, rarity, name}, acc ->
        Map.update(
          acc,
          set_id,
          %{rarity => MapSet.new([name])},
          &Map.update(&1, rarity, MapSet.new([name]), fn names -> MapSet.put(names, name) end)
        )
      end)

    for {set_id, names_by_rarity} <- names_by_set,
        set = Map.get(sets_by_id, set_id),
        not is_nil(set),
        into: %{} do
      totals = Map.new(names_by_rarity, fn {r, names} -> {r, MapSet.size(names)} end)
      {set_id, %__MODULE__{set: set, totals: totals, names_by_rarity: names_by_rarity}}
    end
  end

  # Sets whose entire `cards_cards` slice has `is_booster = false` —
  # almost certainly Scryfall lag, not a deliberate "no boosters in
  # this set" decision. Returned as a `MapSet` so the membership check
  # in the main query stays cheap regardless of how many sets are in
  # the lag bucket.
  @spec sets_with_no_booster_signal() :: MapSet.t(integer())
  defp sets_with_no_booster_signal do
    Card
    |> where([c], not is_nil(c.set_id))
    |> group_by([c], c.set_id)
    |> having([c], sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.is_booster)) == 0)
    |> select([c], c.set_id)
    |> Repo.all()
    |> MapSet.new()
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
