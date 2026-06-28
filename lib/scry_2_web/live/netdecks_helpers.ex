defmodule Scry2Web.NetdecksHelpers do
  @moduledoc "Pure helpers for `Scry2Web.NetdecksLive` (ADR-013)."

  @order [common: "c", uncommon: "u", rare: "r", mythic: "m"]

  @doc ~s(Compact wildcard-cost label, e.g. "2u 1r". Returns "—" when zero.)
  @spec format_cost(map()) :: String.t()
  def format_cost(cost) do
    parts =
      for {rarity, suffix} <- @order,
          (count = Map.get(cost, rarity, 0)) > 0,
          do: "#{count}#{suffix}"

    case parts do
      [] -> "—"
      _ -> Enum.join(parts, " ")
    end
  end

  @spec format_owned_pct(float()) :: String.t()
  def format_owned_pct(fraction), do: "#{round(fraction * 100)}%"

  @doc "True if the entry's deck name or archetype contains `query` (case-insensitive). Empty query matches all."
  @spec match_search?(map(), String.t()) :: boolean()
  def match_search?(_entry, ""), do: true

  def match_search?(%{deck: deck}, query) do
    query_lower = String.downcase(query)
    contains?(deck.name, query_lower) or contains?(deck.archetype, query_lower)
  end

  defp contains?(nil, _query_lower), do: false
  defp contains?(value, query_lower), do: String.contains?(String.downcase(value), query_lower)
end
