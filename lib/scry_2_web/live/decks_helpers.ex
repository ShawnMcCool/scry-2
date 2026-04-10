defmodule Scry2Web.DecksHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DecksLive`. Extracted per ADR-013.
  """

  # ── Display formatting ─────────────────────────────────────────────

  @doc "Returns the deck_colors string for mana pip rendering."
  @spec deck_colors(map()) :: String.t()
  def deck_colors(%{deck_colors: colors}) when is_binary(colors), do: colors
  def deck_colors(_), do: ""

  @doc "Returns a relative time string from a UTC datetime."
  @spec relative_time(DateTime.t() | nil) :: String.t()
  def relative_time(nil), do: "—"

  def relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> format_date(dt)
    end
  end

  @doc "Returns a human-readable date string from a UTC datetime."
  @spec format_date(DateTime.t() | nil) :: String.t()
  def format_date(nil), do: "—"

  def format_date(dt) do
    date = DateTime.to_date(dt)
    "#{date.year}-#{pad(date.month)}-#{pad(date.day)}"
  end

  @doc "Returns a Tailwind text-color class based on win rate."
  @spec win_rate_class(float() | nil) :: String.t()
  def win_rate_class(nil), do: "text-base-content/40"
  def win_rate_class(rate) when rate >= 55.0, do: "text-emerald-400"
  def win_rate_class(rate) when rate >= 45.0, do: "text-base-content"
  def win_rate_class(_), do: "text-red-400"

  @doc "Returns a formatted win rate string like '55.3%' or '—' if nil."
  @spec format_win_rate(float() | nil) :: String.t()
  def format_win_rate(nil), do: "—"
  def format_win_rate(rate), do: "#{rate}%"

  @doc "Returns a 'NW–ML' record string."
  @spec record_str(integer(), integer()) :: String.t()
  def record_str(nil, _), do: ""
  def record_str(_, nil), do: ""
  def record_str(wins, losses), do: "#{wins}W–#{losses}L"

  @doc "Returns a card name by arena_id from the cards lookup map, or a fallback."
  @spec card_name(integer() | nil, map()) :: String.t()
  def card_name(nil, _), do: "Unknown"

  def card_name(arena_id, cards_by_arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      nil -> "#{arena_id}"
      card -> card.name
    end
  end

  # ── Card grouping ─────────────────────────────────────────────────

  @doc """
  Groups the deck's current main deck cards by type, resolving names from
  the cards lookup. Returns a list of `{type_label, [%{count, name, arena_id}]}`.
  """
  @spec group_deck_cards(map(), map()) :: [{String.t(), list()}]
  def group_deck_cards(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    cards
    |> Enum.map(fn card ->
      arena_id = card["arena_id"] || card[:arena_id]
      count = card["count"] || card[:count] || 1
      card_data = Map.get(cards_by_arena_id, arena_id)
      type = card_type_label(card_data)
      mana_value = (card_data && card_data.mana_value) || 99

      %{
        arena_id: arena_id,
        count: count,
        name: card_name(arena_id, cards_by_arena_id),
        type: type,
        mana_value: mana_value
      }
    end)
    |> Enum.sort_by(&{type_order(&1.type), &1.mana_value, &1.name})
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} -> type_order(type) end)
  end

  @doc """
  Returns a JSON-encoded series for the mana curve ECharts bar chart.
  Lands are excluded. Format: `[[cmc_label, count], ...]`
  """
  @spec mana_curve_series(map(), map()) :: String.t()
  def mana_curve_series(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    curve =
      cards
      |> Enum.flat_map(fn card ->
        arena_id = card["arena_id"] || card[:arena_id]
        count = card["count"] || card[:count] || 1
        card_data = Map.get(cards_by_arena_id, arena_id)

        if land?(card_data) do
          []
        else
          mv = min((card_data && card_data.mana_value) || 0, 7)
          List.duplicate(mv, count)
        end
      end)
      |> Enum.frequencies()

    0..7
    |> Enum.map(fn mv ->
      label = if mv >= 7, do: "7+", else: "#{mv}"
      [label, Map.get(curve, mv, 0)]
    end)
    |> Jason.encode!()
  end

  @doc """
  Groups the deck's current main deck cards by CMC for visual display.
  Returns `[{cmc_label, [%{arena_id, name, count}]}]` sorted CMC 0–7+, then Lands last.
  """
  @spec group_cards_by_cmc(map(), map()) :: [{String.t(), list()}]
  def group_cards_by_cmc(deck, cards_by_arena_id) do
    cards =
      case deck.current_main_deck do
        %{"cards" => card_list} -> card_list
        _ -> []
      end

    cards
    |> Enum.map(fn card ->
      arena_id = card["arena_id"] || card[:arena_id]
      count = card["count"] || card[:count] || 1
      card_data = Map.get(cards_by_arena_id, arena_id)
      cmc_key = card_cmc(card_data)

      %{
        arena_id: arena_id,
        count: count,
        name: card_name(arena_id, cards_by_arena_id),
        cmc_key: cmc_key
      }
    end)
    |> Enum.sort_by(&{&1.cmc_key, &1.name})
    |> Enum.group_by(& &1.cmc_key)
    |> Enum.map(fn {cmc_key, group_cards} -> {cmc_label(cmc_key), group_cards} end)
    |> Enum.sort_by(fn {_, [first | _]} -> first.cmc_key end)
  end

  @doc """
  Returns sideboard cards as a flat list sorted by mana value then name, for horizontal display.
  Each entry is `%{arena_id, count, name, mana_value}`.
  """
  @spec sideboard_cards(map(), map()) :: [
          %{
            arena_id: integer(),
            count: integer(),
            name: String.t(),
            mana_value: non_neg_integer()
          }
        ]
  def sideboard_cards(deck, cards_by_arena_id) do
    case deck.current_sideboard do
      %{"cards" => card_list} ->
        card_list
        |> Enum.map(fn card ->
          arena_id = card["arena_id"] || card[:arena_id]
          count = card["count"] || card[:count] || 1
          card_data = Map.get(cards_by_arena_id, arena_id)
          mana_value = (card_data && card_data.mana_value) || 99

          %{
            arena_id: arena_id,
            count: count,
            name: card_name(arena_id, cards_by_arena_id),
            mana_value: mana_value
          }
        end)
        |> Enum.sort_by(&{&1.mana_value, &1.name})

      _ ->
        []
    end
  end

  @doc """
  Returns a JSON-encoded series for the win rate over time ECharts line chart.
  Format: `%{weeks: [...], bo1: [...], bo3: [...]}`
  """
  @spec winrate_series(list()) :: String.t()
  def winrate_series(win_rate_by_week) do
    weeks = Enum.map(win_rate_by_week, & &1.week)
    bo1 = Enum.map(win_rate_by_week, & &1.bo1_win_rate)
    bo3 = Enum.map(win_rate_by_week, & &1.bo3_win_rate)

    Jason.encode!(%{weeks: weeks, bo1: bo1, bo3: bo3})
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp land?(nil), do: false
  defp land?(card_data), do: String.contains?(card_data.types || "", "Land")

  # CMC key: integer 0–7 for spells (7 = "7+"), 8 for lands (sort last)
  defp card_cmc(nil), do: 0

  defp card_cmc(card_data),
    do: if(land?(card_data), do: 8, else: min(card_data.mana_value || 0, 7))

  defp cmc_label(8), do: "Land"
  defp cmc_label(7), do: "7+"
  defp cmc_label(n), do: "#{n}"

  defp card_type_label(nil), do: "Unknown"

  defp card_type_label(card) do
    types = card.types || ""

    cond do
      String.contains?(types, "Creature") -> "Creatures"
      String.contains?(types, "Planeswalker") -> "Planeswalkers"
      String.contains?(types, "Instant") -> "Instants"
      String.contains?(types, "Sorcery") -> "Sorceries"
      String.contains?(types, "Enchantment") -> "Enchantments"
      String.contains?(types, "Artifact") -> "Artifacts"
      String.contains?(types, "Land") -> "Lands"
      true -> "Other"
    end
  end

  defp type_order("Creatures"), do: 0
  defp type_order("Planeswalkers"), do: 1
  defp type_order("Instants"), do: 2
  defp type_order("Sorceries"), do: 3
  defp type_order("Enchantments"), do: 4
  defp type_order("Artifacts"), do: 5
  defp type_order("Lands"), do: 6
  defp type_order(_), do: 7
end
