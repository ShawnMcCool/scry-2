defmodule Scry2.Collection.Completion do
  @moduledoc """
  Per-set rarity-banded completion ratios.

  Pure value derived from a list of `Scry2.Collection.Holding` and a
  `%{set_id => Scry2.Cards.SetRoster.t()}` map. Every set in the roster
  map produces one `Completion`, even when nothing from it is owned —
  so the UI can show "I own 0 of 30 cards from FDN" without special-casing.

  Holdings whose `card.set_id` does not appear in the roster map are
  ignored (e.g. cards from a set that has not been imported yet).
  """

  alias Scry2.Cards.{Set, SetRoster}
  alias Scry2.Collection.Holding

  @enforce_keys [:set, :owned_unique, :total_unique, :by_rarity]
  defstruct [:set, :owned_unique, :total_unique, :by_rarity]

  @type rarity_row :: %{owned: non_neg_integer(), total: non_neg_integer()}

  @type t :: %__MODULE__{
          set: Set.t(),
          owned_unique: non_neg_integer(),
          total_unique: non_neg_integer(),
          by_rarity: %{String.t() => rarity_row()}
        }

  @spec from_holdings([Holding.t()], %{integer() => SetRoster.t()}) :: [t()]
  def from_holdings(holdings, rosters) when is_list(holdings) and is_map(rosters) do
    owned_by_set =
      Enum.reduce(holdings, %{}, fn holding, acc ->
        set_id = holding.card.set_id

        cond do
          is_nil(set_id) ->
            acc

          not Map.has_key?(rosters, set_id) ->
            acc

          true ->
            rarity = holding.card.rarity || "unknown"

            Map.update(
              acc,
              set_id,
              %{rarity => 1},
              &Map.update(&1, rarity, 1, fn n -> n + 1 end)
            )
        end
      end)

    rosters
    |> Enum.map(fn {set_id, roster} ->
      build_completion(roster, Map.get(owned_by_set, set_id, %{}))
    end)
    |> Enum.sort_by(&sort_key(&1.set), :desc)
  end

  @doc "Convenience ratio of `owned_unique / total_unique`, clamped to [0.0, 1.0]."
  @spec completion_ratio(t()) :: float()
  def completion_ratio(%__MODULE__{total_unique: 0}), do: 0.0

  def completion_ratio(%__MODULE__{owned_unique: owned, total_unique: total}) do
    owned / total
  end

  defp build_completion(%SetRoster{set: set, totals: totals}, owned_by_rarity) do
    by_rarity =
      totals
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(owned_by_rarity)))
      |> Enum.reduce(%{}, fn rarity, acc ->
        Map.put(acc, rarity, %{
          owned: Map.get(owned_by_rarity, rarity, 0),
          total: Map.get(totals, rarity, 0)
        })
      end)

    %__MODULE__{
      set: set,
      owned_unique: Enum.reduce(owned_by_rarity, 0, fn {_, n}, acc -> acc + n end),
      total_unique: Enum.reduce(totals, 0, fn {_, n}, acc -> acc + n end),
      by_rarity: by_rarity
    }
  end

  # Newest released_at first; nil dates sort last; ties broken by code asc.
  #
  # Dates are converted to `{y, m, d}` erl tuples because `Enum.sort_by/3`
  # with `:desc` uses term comparison, and `%Date{}` structs sort by
  # alphabetical map-key order (`:calendar`, `:day`, `:month`, `:year`),
  # which yields a day-of-month sort instead of a chronological one.
  defp sort_key(%Set{released_at: nil, code: code}), do: {0, {0, 0, 0}, code}
  defp sort_key(%Set{released_at: date, code: code}), do: {1, Date.to_erl(date), code}
end
