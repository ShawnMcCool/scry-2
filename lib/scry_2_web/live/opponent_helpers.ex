defmodule Scry2Web.OpponentHelpers do
  @moduledoc """
  Pure helper functions for the `<.opponent_panel>` component.

  Input: a list of `%Scry2.Matches.Match{}` structs (previous matches against
  the same opponent, in any order).

  Output: computed display values — record counts, win rate, chart series,
  latest known rank.
  """

  alias Scry2Web.LiveHelpers

  @doc """
  Returns `{wins, losses}` counts from a list of matches.
  Matches with `nil` won (in-progress or unknown outcome) are ignored.
  """
  @spec record(list()) :: {non_neg_integer(), non_neg_integer()}
  def record(history) do
    wins = Enum.count(history, &(&1.won == true))
    losses = Enum.count(history, &(&1.won == false))
    {wins, losses}
  end

  @doc """
  Returns win rate as a float (0.0–100.0), or `nil` if no completed matches.
  """
  @spec win_rate(non_neg_integer(), non_neg_integer()) :: float() | nil
  def win_rate(wins, losses) do
    total = wins + losses
    if total == 0, do: nil, else: Float.round(wins / total * 100, 1)
  end

  @doc """
  Returns the most recent known rank string from the history (the rank from the
  most recent match that has a non-nil `opponent_rank`), or `nil` if no match
  in the history carries a rank.
  """
  @spec latest_rank(list()) :: String.t() | nil
  def latest_rank([]), do: nil

  def latest_rank(history) do
    history
    |> Enum.filter(&(not is_nil(&1.opponent_rank)))
    |> case do
      [] -> nil
      ranked -> Enum.max_by(ranked, & &1.started_at, DateTime) |> Map.get(:opponent_rank)
    end
  end

  @doc """
  Builds the JSON-encoded cumulative win rate series for the `Chart` hook.

  Accepts matches in any order; sorts ascending by `started_at` before
  computing. Excludes matches with `nil` won. Returns `"[]"` if fewer than 3
  matches are present — the panel suppresses the chart at that threshold.
  """
  @spec chart_series(list()) :: String.t()
  def chart_series([]), do: "[]"
  def chart_series([_]), do: "[]"
  def chart_series([_, _]), do: "[]"

  def chart_series(history) do
    history
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.filter(&(not is_nil(&1.won)))
    |> Enum.reduce({0, 0, []}, fn match, {wins, total, acc} ->
      wins = if match.won, do: wins + 1, else: wins
      total = total + 1
      rate = Float.round(wins / total * 100, 1)

      point = %{
        timestamp: DateTime.to_iso8601(match.started_at),
        win_rate: rate,
        wins: wins,
        total: total
      }

      {wins, total, [point | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
    |> LiveHelpers.cumulative_winrate_series()
  end
end
