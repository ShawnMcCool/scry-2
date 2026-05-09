defmodule Scry2.Analytics.RollingWindow do
  @moduledoc """
  Rolling and cumulative win-rate computation over a time-ordered sequence
  of match-like events.

  Inputs are plain `%{started_at: DateTime.t(), won: boolean()}` rows, sorted
  ascending by `started_at`. Output is `[%{timestamp, win_rate, wins, total}]`.

  Two modes:

    * `cumulative_points/1` — every point counts every prior match up to and
      including itself. Use when no time window is requested.

    * `rolling_points/2` — for each match, the window is
      `[match.started_at - N days, match.started_at]`. Two-pointer sliding
      window: O(n) overall, both pointers move forward monotonically.

  A minimum sample threshold (`@min_samples`) is applied to `rolling_points/2`
  to avoid emitting noisy 0% / 100% lines when the window only contains a
  handful of matches.
  """

  # A 1- or 2-sample rolling rate is always 0% or 100% — too noisy to plot.
  # With 5W+5L behind the first emitted point the line is informative.
  @min_samples 5

  @type row :: %{required(:started_at) => DateTime.t(), required(:won) => boolean()}
  @type point :: %{
          required(:timestamp) => String.t(),
          required(:win_rate) => float() | nil,
          required(:wins) => non_neg_integer(),
          required(:total) => non_neg_integer()
        }

  @doc """
  Cumulative win-rate points: each point's rate is computed from all rows
  up to and including itself.
  """
  @spec cumulative_points([row()]) :: [point()]
  def cumulative_points(rows) do
    rows
    |> Enum.reduce({0, 0, []}, fn row, {wins, total, acc} ->
      wins = if row.won, do: wins + 1, else: wins
      total = total + 1
      {wins, total, [point(row.started_at, wins, total) | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  @doc """
  Rolling win-rate points over a `days`-day window. Points whose window
  contains fewer than 5 samples are omitted.
  """
  @spec rolling_points([row()], pos_integer()) :: [point()]
  def rolling_points([], _days), do: []

  def rolling_points(rows, days) when is_integer(days) and days > 0 do
    window_seconds = days * 86_400
    indexed = rows |> Enum.with_index() |> Map.new(fn {row, index} -> {index, row} end)
    last_index = map_size(indexed) - 1

    {points, _} =
      Enum.reduce(0..last_index//1, {[], 0}, fn right, {acc, left} ->
        cutoff = DateTime.add(indexed[right].started_at, -window_seconds, :second)
        new_left = advance_left(indexed, left, right, cutoff)
        {wins, total} = count_window(indexed, new_left, right)

        if total >= @min_samples do
          {[point(indexed[right].started_at, wins, total) | acc], new_left}
        else
          {acc, new_left}
        end
      end)

    Enum.reverse(points)
  end

  @doc """
  Trims a list of points to those whose timestamp falls within the visible
  window `[now - days, now]`. The rolling computation already considers
  earlier rows as context for points near the left edge, so this is purely
  a display-side filter.
  """
  @spec filter_to_display_window([point()], pos_integer(), DateTime.t()) :: [point()]
  def filter_to_display_window(points, days, now) do
    cutoff_iso = now |> DateTime.add(-days, :day) |> DateTime.to_iso8601()
    Enum.filter(points, &(&1.timestamp >= cutoff_iso))
  end

  defp advance_left(indexed, left, right, cutoff) do
    if left <= right and DateTime.compare(indexed[left].started_at, cutoff) == :lt do
      advance_left(indexed, left + 1, right, cutoff)
    else
      left
    end
  end

  defp count_window(indexed, left, right) do
    Enum.reduce(left..right//1, {0, 0}, fn index, {wins, total} ->
      if indexed[index].won, do: {wins + 1, total + 1}, else: {wins, total + 1}
    end)
  end

  defp point(started_at, wins, total) do
    %{
      timestamp: DateTime.to_iso8601(started_at),
      win_rate: win_rate(wins, total),
      wins: wins,
      total: total
    }
  end

  defp win_rate(_wins, 0), do: nil
  defp win_rate(wins, total), do: Float.round(wins / total * 100, 1)
end
