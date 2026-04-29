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
  Builds the JSON-encoded win-rate series for the `Chart` hook.

  Accepts matches in any order; sorts ascending by `started_at` before
  computing. Excludes matches with `nil` won. Returns `"[]"` if fewer than 3
  matches are present — the panel suppresses the chart at that threshold.

  Options:
    * `:days` — rolling-window size in days. Defaults to nil (cumulative).
  """
  @spec chart_series(list(), keyword()) :: String.t()
  def chart_series(history, opts \\ [])

  def chart_series([], _opts), do: "[]"
  def chart_series([_], _opts), do: "[]"
  def chart_series([_, _], _opts), do: "[]"

  def chart_series(history, opts) do
    days = Keyword.get(opts, :days)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    sorted =
      history
      |> Enum.sort_by(& &1.started_at, DateTime)
      |> Enum.filter(&(not is_nil(&1.won)))

    points =
      case days do
        nil ->
          cumulative_points(sorted)

        n when is_integer(n) and n > 0 ->
          sorted
          |> rolling_points(n)
          |> filter_to_display_window(n, now)
      end

    LiveHelpers.cumulative_winrate_series(points)
  end

  defp filter_to_display_window(points, days, now) do
    cutoff_iso = now |> DateTime.add(-days, :day) |> DateTime.to_iso8601()
    Enum.filter(points, &(&1.timestamp >= cutoff_iso))
  end

  defp cumulative_points(matches) do
    matches
    |> Enum.reduce({0, 0, []}, fn match, {wins, total, acc} ->
      wins = if match.won, do: wins + 1, else: wins
      total = total + 1

      point = %{
        timestamp: DateTime.to_iso8601(match.started_at),
        win_rate: Float.round(wins / total * 100, 1),
        wins: wins,
        total: total
      }

      {wins, total, [point | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  # Mirrors the Matches.rolling_win_rate two-pointer pattern over an
  # in-memory list (no DB query — opponent history is already loaded).
  # Min-samples threshold matches Scry2.Matches.
  @rolling_min_samples 5

  defp rolling_points([], _days), do: []

  defp rolling_points(matches, days) do
    window_seconds = days * 86_400
    indexed = matches |> Enum.with_index() |> Map.new(fn {m, i} -> {i, m} end)
    n = map_size(indexed)

    {points, _} =
      Enum.reduce(0..(n - 1)//1, {[], 0}, fn i, {acc, left} ->
        cutoff = DateTime.add(indexed[i].started_at, -window_seconds, :second)
        new_left = advance_left(indexed, left, i, cutoff)
        {wins, total} = count_window(indexed, new_left, i)

        if total >= @rolling_min_samples do
          point = %{
            timestamp: DateTime.to_iso8601(indexed[i].started_at),
            win_rate: Float.round(wins / total * 100, 1),
            wins: wins,
            total: total
          }

          {[point | acc], new_left}
        else
          {acc, new_left}
        end
      end)

    Enum.reverse(points)
  end

  defp advance_left(indexed, left, right, cutoff) do
    if left <= right and DateTime.compare(indexed[left].started_at, cutoff) == :lt do
      advance_left(indexed, left + 1, right, cutoff)
    else
      left
    end
  end

  defp count_window(indexed, left, right) do
    Enum.reduce(left..right//1, {0, 0}, fn i, {wins, total} ->
      if indexed[i].won, do: {wins + 1, total + 1}, else: {wins, total + 1}
    end)
  end
end
