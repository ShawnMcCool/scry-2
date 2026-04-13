defmodule Scry2Web.PlayerHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.PlayerLive`. Extracted per ADR-013.
  """

  @doc """
  Formats a win rate float as a percentage string.
  Returns "—" for nil (no data).
  """
  @spec format_win_rate(float() | nil) :: String.t()
  def format_win_rate(nil), do: "—"
  def format_win_rate(rate), do: "#{rate}%"

  @doc """
  Returns a Tailwind text-color class for a win rate value.
  Green above 50%, red below, neutral at 50% or nil.
  """
  @spec win_rate_class(float() | nil) :: String.t()
  def win_rate_class(nil), do: "text-base-content/50"
  def win_rate_class(rate) when rate > 50.0, do: "text-emerald-400"
  def win_rate_class(rate) when rate < 50.0, do: "text-red-400"
  def win_rate_class(_rate), do: "text-base-content"

  @doc """
  Formats a float stat (avg turns, avg mulligans) for display.
  """
  @spec format_avg(float() | nil) :: String.t()
  def format_avg(nil), do: "—"
  def format_avg(value), do: :erlang.float_to_binary(value, decimals: 1)

  @doc """
  Returns a W–L record string from wins and losses counts.
  """
  @spec record(integer(), integer()) :: String.t()
  def record(wins, losses), do: "#{wins}–#{losses}"

  @doc """
  Formats a streak tuple as a display string like "W4" or "L2".
  Returns "—" for no streak.
  """
  @spec format_streak({:win | :loss | :none, non_neg_integer()}) :: String.t()
  def format_streak({:none, _}), do: "—"
  def format_streak({:win, count}), do: "W#{count}"
  def format_streak({:loss, count}), do: "L#{count}"

  @doc """
  Returns a Tailwind text-color class for a streak value.
  """
  @spec streak_class({:win | :loss | :none, non_neg_integer()}) :: String.t()
  def streak_class({:win, _}), do: "text-emerald-400"
  def streak_class({:loss, _}), do: "text-red-400"
  def streak_class({:none, _}), do: "text-base-content/50"

  @doc """
  Returns the top N decks sorted by win rate, requiring a minimum match count.

  Each entry in `decks_with_stats` is `%{deck: %Deck{}, bo1: %{...}, bo3: %{...}}`.
  Combines BO1 + BO3 totals for ranking.
  """
  @spec top_decks(list(map()), non_neg_integer(), non_neg_integer()) :: list(map())
  def top_decks(decks_with_stats, limit \\ 5, min_matches \\ 3) do
    decks_with_stats
    |> Enum.map(fn entry ->
      total = entry.bo1.total + entry.bo3.total
      wins = entry.bo1.wins + entry.bo3.wins
      losses = entry.bo1.losses + entry.bo3.losses
      win_rate = if total > 0, do: Float.round(wins / total * 100, 1)

      %{
        name: entry.deck.current_name,
        mtga_deck_id: entry.deck.mtga_deck_id,
        deck_colors: entry.deck.deck_colors,
        total: total,
        wins: wins,
        losses: losses,
        win_rate: win_rate
      }
    end)
    |> Enum.filter(fn deck -> deck.total >= min_matches end)
    |> Enum.sort_by(fn deck -> deck.win_rate || 0 end, :desc)
    |> Enum.take(limit)
  end
end
