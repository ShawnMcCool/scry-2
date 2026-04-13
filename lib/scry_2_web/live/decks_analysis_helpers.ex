defmodule Scry2Web.DecksAnalysisHelpers do
  @moduledoc """
  Pure helper functions for the deck analysis tab.

  Handles heatmap formatting, card performance table preparation,
  and metric definitions for tooltips.
  """

  @doc """
  Returns the CSS class for a win rate value in the heatmap.
  Green for > 55%, yellow for 45-55%, red for < 45%.
  """
  def heatmap_cell_class(nil), do: "bg-base-300 text-base-content/30"
  def heatmap_cell_class(win_rate) when win_rate >= 55, do: "bg-success/30 text-success"
  def heatmap_cell_class(win_rate) when win_rate >= 45, do: "bg-warning/30 text-warning"
  def heatmap_cell_class(_win_rate), do: "bg-error/30 text-error"

  @doc """
  Returns the CSS class for an IWD value.
  Green for positive (drawing helps), red for negative (drawing hurts).
  """
  def iwd_class(nil), do: "text-base-content/30"
  def iwd_class(iwd) when iwd > 0, do: "text-success"
  def iwd_class(iwd) when iwd < 0, do: "text-error"
  def iwd_class(_), do: "text-base-content/50"

  @doc """
  Formats a percentage with one decimal place and % suffix, or "—" for nil.
  """
  def format_pct(nil), do: "—"
  def format_pct(value) when is_float(value), do: "#{format_number(value)}%"

  @doc """
  Formats IWD with a sign prefix: "+5.2pp", "-3.1pp", or "—" for nil.
  """
  def format_iwd(nil), do: "—"
  def format_iwd(value) when value > 0, do: "+#{format_number(value)}"
  def format_iwd(value), do: "#{format_number(value)}"

  # Drops trailing ".0" from floats: 100.0 → "100", 66.7 → "66.7"
  defp format_number(value) when is_float(value) do
    if value == trunc(value), do: "#{trunc(value)}", else: "#{value}"
  end

  @doc """
  Returns true if the sample size is too small for meaningful stats (< 5 games).
  """
  def low_sample?(games), do: games < 5

  @doc """
  Looks up a heatmap cell value for a given hand_size and land_count.
  Returns the cell map or nil.
  """
  def heatmap_cell(heatmap, hand_size, land_count) do
    Enum.find(heatmap, &(&1.hand_size == hand_size && &1.land_count == land_count))
  end

  @doc """
  Sorts and optionally groups card performance entries.

  Sort modes:
    * `:type` — grouped by card type (Creatures, Instants, etc.), IWD descending within
    * `:iwd` — flat list sorted by IWD descending
    * `:oh_wr` — flat list sorted by OH WR descending
    * `:gih_wr` — flat list sorted by GIH WR descending
    * `:name` — flat list sorted alphabetically

  Returns `[{group_label | nil, [card]}]`. Grouped modes return type labels;
  flat modes return a single `{nil, sorted_list}`.
  """
  def sort_cards(card_performance, cards_by_arena_id, deck, sort_mode) do
    sideboard_ids = sideboard_arena_ids(deck)

    {side_cards, main_cards} =
      card_performance
      |> Enum.map(fn card ->
        card_data = Map.get(cards_by_arena_id, card.card_arena_id)
        Map.put(card, :type, card_type_label(card_data))
      end)
      |> Enum.split_with(&MapSet.member?(sideboard_ids, &1.card_arena_id))

    main_groups =
      case sort_mode do
        :type ->
          main_cards
          |> Enum.sort_by(&{type_order(&1.type), -(&1.iwd || -999)})
          |> Enum.group_by(& &1.type)
          |> Enum.sort_by(fn {type, _} -> type_order(type) end)

        :name ->
          [{nil, Enum.sort_by(main_cards, &(&1.card_name || "zzz"))}]

        sort_key when sort_key in [:iwd, :oh_wr, :gih_wr] ->
          [{nil, Enum.sort_by(main_cards, &(-(&1[sort_key] || -999)))}]

        _ ->
          [{nil, main_cards}]
      end

    if side_cards == [] do
      main_groups
    else
      sorted_side = Enum.sort_by(side_cards, &(-(&1.iwd || -999)))
      main_groups ++ [{"Sideboard", sorted_side}]
    end
  end

  defp sideboard_arena_ids(nil), do: MapSet.new()

  defp sideboard_arena_ids(deck) do
    cards = (deck.current_sideboard && deck.current_sideboard["cards"]) || []
    MapSet.new(cards, fn card -> card["arena_id"] || card[:arena_id] end)
  end

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

  @doc """
  Returns metric definitions for tooltips in the UI. Each metric has a short
  name, a full name, and a plain-English explanation.
  """
  def metric_definitions do
    %{
      oh_wr: %{
        short: "OH WR",
        name: "Opening Hand Win Rate",
        description: "Your win rate in games where this card was in your opening hand."
      },
      gih_wr: %{
        short: "GIH WR",
        name: "Game in Hand Win Rate",
        description:
          "Your win rate in games where this card was drawn at any point — opening hand or during the game. The strongest single signal of a card's performance in your deck."
      },
      gd_wr: %{
        short: "GD WR",
        name: "Games Drawn Win Rate",
        description:
          "Your win rate when this card was drawn during the game (not in your opening hand). Indicates topdeck quality and late-game impact. Biased toward longer games."
      },
      gnd_wr: %{
        short: "GND WR",
        name: "Game Not Drawn Win Rate",
        description:
          "Your win rate in games where this card was in your deck but never drawn. Acts as a baseline — how you perform without this card's help."
      },
      iwd: %{
        short: "IWD",
        name: "Improvement When Drawn",
        description:
          "GIH WR minus GND WR, in percentage points. Positive means drawing this card improves your win rate. Negative means drawing it correlates with losing. The bigger the number, the more impactful."
      }
    }
  end
end
