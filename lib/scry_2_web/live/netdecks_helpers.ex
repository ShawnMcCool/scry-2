defmodule Scry2Web.NetdecksHelpers do
  @moduledoc "Pure helpers for `Scry2Web.NetdecksLive` (ADR-013)."

  @order [common: "c", uncommon: "u", rare: "r", mythic: "m"]
  @rarity_order [:common, :uncommon, :rare, :mythic]

  # Presentation metadata per buildability status. `section` is the group
  # heading in the catalog; `label` is the compact per-deck badge text.
  @statuses %{
    buildable: %{
      label: "Buildable",
      section: "Buildable now",
      badge: "badge-soft badge-success",
      icon: "hero-check-circle",
      tone: "text-success"
    },
    craftable: %{
      label: "Craftable",
      section: "Craftable now",
      badge: "badge-soft badge-info",
      icon: "hero-sparkles",
      tone: "text-info"
    },
    short: %{
      label: "Short",
      section: "Within reach",
      badge: "badge-ghost",
      icon: "hero-arrow-trending-up",
      tone: "text-base-content/40"
    }
  }

  @doc "Relative time label (e.g. \"3 days ago\") — delegated to the shared helper."
  defdelegate relative_time(datetime), to: Scry2Web.LiveHelpers

  @doc "Status group order, cheapest/most-ready first."
  @spec status_order() :: [:buildable | :craftable | :short]
  def status_order, do: [:buildable, :craftable, :short]

  @doc "Presentation metadata (label, section heading, badge/icon classes) for a status."
  @spec status_meta(:buildable | :craftable | :short) :: map()
  def status_meta(status), do: Map.fetch!(@statuses, status)

  @doc """
  Non-zero wildcard-cost entries as `{rarity, count}` in common→mythic order,
  for rendering rarity-coloured pips.
  """
  @spec cost_pips(map()) :: [{atom(), integer()}]
  def cost_pips(cost) do
    for rarity <- @rarity_order, (count = Map.get(cost, rarity, 0)) > 0, do: {rarity, count}
  end

  @doc "True if a cost/shortfall map has any non-zero rarity."
  @spec any_cost?(map()) :: boolean()
  def any_cost?(cost), do: cost_pips(cost) != []

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

  @doc "Whole-percent label for an owned fraction (0.0–1.0), e.g. \"82%\"."
  @spec format_owned_pct(float()) :: String.t()
  def format_owned_pct(fraction), do: "#{round(fraction * 100)}%"

  @doc """
  Per-card ownership state for styling a decklist row:
  `:free` (basic land), `:owned` (have all needed), `:missing` (own none),
  `:partial` (own some but not all).
  """
  @spec card_row_state(map()) :: :free | :owned | :missing | :partial
  def card_row_state(%{free?: true}), do: :free
  def card_row_state(%{missing: 0}), do: :owned
  def card_row_state(%{owned: 0}), do: :missing
  def card_row_state(_row), do: :partial

  @doc "Text-colour class for a decklist row's ownership state."
  @spec card_row_tone(:free | :owned | :missing | :partial) :: String.t()
  def card_row_tone(:free), do: "text-base-content/30"
  def card_row_tone(:owned), do: "text-success"
  def card_row_tone(:missing), do: "text-warning"
  def card_row_tone(:partial), do: "text-base-content/60"

  @doc "Count of references on a deck that did not resolve to an arena_id."
  @spec unresolved_count(map()) :: non_neg_integer()
  def unresolved_count(%{unresolved_cards: %{"cards" => cards}}) when is_list(cards),
    do: length(cards)

  def unresolved_count(_deck), do: 0

  @doc "True if the entry's deck name or archetype contains `query` (case-insensitive). Empty query matches all."
  @spec match_search?(map(), String.t()) :: boolean()
  def match_search?(_entry, ""), do: true

  def match_search?(%{deck: deck}, query) do
    query_lower = String.downcase(query)
    contains?(deck.name, query_lower) or contains?(deck.archetype, query_lower)
  end

  defp contains?(nil, _query_lower), do: false
  defp contains?(value, query_lower), do: String.contains?(String.downcase(value), query_lower)

  @doc """
  Per-source deck counts and latest fetch time for the catalog status strip.

  Returns `[%{source_name, count, latest}]` sorted by source name.
  """
  def source_summary(decks) do
    decks
    |> Enum.group_by(& &1.source_name)
    |> Enum.map(fn {source_name, group} ->
      %{
        source_name: source_name,
        count: length(group),
        latest: group |> Enum.map(& &1.fetched_at) |> Enum.max(DateTime)
      }
    end)
    |> Enum.sort_by(& &1.source_name)
  end
end
