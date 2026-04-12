defmodule Scry2Web.RanksHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.RanksLive`. Extracted per ADR-013.
  """

  @class_order ~w(Bronze Silver Gold Platinum Diamond)

  @doc """
  Formats a rank as "Class Level" (e.g. "Gold 1").
  Returns "—" when class is nil.
  """
  @spec format_rank(String.t() | nil, integer() | nil) :: String.t()
  def format_rank(nil, _level), do: "—"
  def format_rank(class, nil), do: class
  def format_rank(class, level), do: "#{class} #{level}"

  @doc """
  Returns a W–L record string from won/lost counts.
  """
  @spec format_record(integer() | nil, integer() | nil) :: String.t()
  def format_record(nil, _), do: "—"
  def format_record(_, nil), do: "—"
  def format_record(won, lost), do: "#{won}–#{lost}"

  @doc """
  Returns the number of pips (steps) filled for the current rank step.
  MTGA ranks have 6 steps per level (0–5), displayed as filled/empty pips.
  """
  @spec step_pips(integer() | nil) :: {integer(), integer()}
  def step_pips(nil), do: {0, 6}
  def step_pips(step), do: {step, 6}

  @doc """
  Converts a rank class/level/step into a continuous integer score for chart Y-axis.

  Scale: Bronze 4/step 0 = 0, Mythic = 120.
  Formula: class_index * 24 + (4 - level) * 6 + step
  Mythic is treated as a flat tier at 120 with no level/step sub-ranking.
  """
  @spec rank_score(String.t() | nil, integer() | nil, integer() | nil) :: integer()
  def rank_score(nil, _level, _step), do: 0
  def rank_score("Mythic", _level, _step), do: 120
  def rank_score("Beginner", level, step), do: rank_score("Bronze", level, step)

  def rank_score(class, level, step) do
    class_index = class_to_index(class)
    safe_level = level || 4
    safe_step = step || 0
    class_index * 24 + (4 - safe_level) * 6 + safe_step
  end

  @doc """
  Converts a continuous rank score back to a human-readable label such as "Gold 2".
  Used to display peak rank. Mirrors the `rankLabel` function in chart.js.
  """
  @spec rank_label_from_score(integer()) :: String.t()
  def rank_label_from_score(score) when score >= 120, do: "Mythic"

  def rank_label_from_score(score) do
    class_index = div(score, 24)
    within_class = rem(score, 24)
    level = 4 - div(within_class, 6)
    class = Enum.at(@class_order, class_index, "Bronze")
    "#{class} #{level}"
  end

  @doc """
  Returns the ISO8601 timestamps for the first and last snapshot in the season,
  to use as explicit X-axis bounds on the climb chart so both grids span the
  full data range rather than fitting independently to their own series.

  Returns `{nil, nil}` for an empty list.
  """
  @spec chart_time_bounds([map()]) :: {String.t() | nil, String.t() | nil}
  def chart_time_bounds([]), do: {nil, nil}

  def chart_time_bounds(snapshots) do
    x_min = snapshots |> List.first() |> Map.get(:occurred_at) |> DateTime.to_iso8601()
    x_max = snapshots |> List.last() |> Map.get(:occurred_at) |> DateTime.to_iso8601()
    {x_min, x_max}
  end

  @doc """
  Returns Y-axis tick marks for the climb chart as [{score, label}].
  Each entry marks the bottom of a rank class boundary.
  """
  @spec rank_axis_ticks() :: [{integer(), String.t()}]
  def rank_axis_ticks do
    [
      {0, "Bronze"},
      {24, "Silver"},
      {48, "Gold"},
      {72, "Platinum"},
      {96, "Diamond"},
      {120, "Mythic"}
    ]
  end

  @doc """
  Builds the climb chart data series for a given format.

  Returns a list of `[iso8601_timestamp, score]` pairs suitable for ECharts
  time-axis step-line charts. Each snapshot becomes one point.
  """
  @spec climb_series([map()], :constructed | :limited) :: [[String.t() | integer()]]
  def climb_series(snapshots, :constructed) do
    Enum.map(snapshots, fn snapshot ->
      score =
        rank_score(
          snapshot.constructed_class,
          snapshot.constructed_level,
          snapshot.constructed_step
        )

      [DateTime.to_iso8601(snapshot.occurred_at), score]
    end)
  end

  def climb_series(snapshots, :limited) do
    Enum.map(snapshots, fn snapshot ->
      score =
        rank_score(
          snapshot.limited_class,
          snapshot.limited_level,
          snapshot.limited_step
        )

      [DateTime.to_iso8601(snapshot.occurred_at), score]
    end)
  end

  @doc """
  Builds momentum chart data series for a given format.

  Returns `{wins_series, losses_series}`, each a list of
  `[iso8601_timestamp, count]` pairs. Wins and losses are cumulative
  season totals taken directly from each snapshot.
  """
  @spec momentum_series([map()], :constructed | :limited) ::
          {[[String.t() | integer()]], [[String.t() | integer()]]}
  def momentum_series(snapshots, :constructed) do
    wins =
      Enum.map(snapshots, fn s ->
        [DateTime.to_iso8601(s.occurred_at), s.constructed_matches_won || 0]
      end)

    losses =
      Enum.map(snapshots, fn s ->
        [DateTime.to_iso8601(s.occurred_at), s.constructed_matches_lost || 0]
      end)

    {wins, losses}
  end

  def momentum_series(snapshots, :limited) do
    wins =
      Enum.map(snapshots, fn s ->
        [DateTime.to_iso8601(s.occurred_at), s.limited_matches_won || 0]
      end)

    losses =
      Enum.map(snapshots, fn s ->
        [DateTime.to_iso8601(s.occurred_at), s.limited_matches_lost || 0]
      end)

    {wins, losses}
  end

  @doc """
  Computes win rate as a percentage (0.0–100.0).
  Returns nil when there are no games played or either argument is nil.
  """
  @spec win_rate(integer() | nil, integer() | nil) :: float() | nil
  def win_rate(nil, _), do: nil
  def win_rate(_, nil), do: nil

  def win_rate(won, lost) when won + lost == 0, do: nil

  def win_rate(won, lost) do
    won / (won + lost) * 100.0
  end

  @doc """
  Returns the peak (maximum) rank score across all snapshots for the given format.
  Returns nil for empty snapshot lists.
  """
  @spec peak_rank_score([map()], :constructed | :limited) :: integer() | nil
  def peak_rank_score([], _format), do: nil

  def peak_rank_score(snapshots, :constructed) do
    snapshots
    |> Enum.map(&rank_score(&1.constructed_class, &1.constructed_level, &1.constructed_step))
    |> Enum.max()
  end

  def peak_rank_score(snapshots, :limited) do
    snapshots
    |> Enum.map(&rank_score(&1.limited_class, &1.limited_level, &1.limited_step))
    |> Enum.max()
  end

  @doc """
  Returns the minimum rank score across all snapshots for the given format.
  Returns nil for empty snapshot lists.
  """
  @spec min_rank_score([map()], :constructed | :limited) :: integer() | nil
  def min_rank_score([], _format), do: nil

  def min_rank_score(snapshots, :constructed) do
    snapshots
    |> Enum.map(&rank_score(&1.constructed_class, &1.constructed_level, &1.constructed_step))
    |> Enum.min()
  end

  def min_rank_score(snapshots, :limited) do
    snapshots
    |> Enum.map(&rank_score(&1.limited_class, &1.limited_level, &1.limited_step))
    |> Enum.min()
  end

  @doc """
  Builds a per-match results series for the given format.

  Returns a list of `[iso8601_timestamp, value]` pairs where value is
  `+1` for a win and `-1` for a loss. Computed from deltas between
  consecutive snapshots. Snapshots with no match delta are skipped.
  """
  @spec match_results_series([map()], :constructed | :limited) :: [[String.t() | integer()]]
  def match_results_series(snapshots, _format) when length(snapshots) < 2, do: []

  def match_results_series(snapshots, :constructed) do
    snapshots
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [prev, curr] ->
      delta_wins = (curr.constructed_matches_won || 0) - (prev.constructed_matches_won || 0)
      delta_losses = (curr.constructed_matches_lost || 0) - (prev.constructed_matches_lost || 0)
      match_result_point(curr.occurred_at, delta_wins, delta_losses)
    end)
  end

  def match_results_series(snapshots, :limited) do
    snapshots
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [prev, curr] ->
      delta_wins = (curr.limited_matches_won || 0) - (prev.limited_matches_won || 0)
      delta_losses = (curr.limited_matches_lost || 0) - (prev.limited_matches_lost || 0)
      match_result_point(curr.occurred_at, delta_wins, delta_losses)
    end)
  end

  @doc """
  Builds mythic percentile series for the given format.

  Returns `[[iso8601_timestamp, percentile], ...]`. Snapshots with nil
  percentile are filtered out. Returns empty list for non-mythic seasons.
  """
  @spec percentile_series([map()], :constructed | :limited) :: [[String.t() | float()]]
  def percentile_series(snapshots, :constructed) do
    snapshots
    |> Enum.filter(&(&1.constructed_percentile != nil))
    |> Enum.map(&[DateTime.to_iso8601(&1.occurred_at), &1.constructed_percentile])
  end

  def percentile_series(snapshots, :limited) do
    snapshots
    |> Enum.filter(&(&1.limited_percentile != nil))
    |> Enum.map(&[DateTime.to_iso8601(&1.occurred_at), &1.limited_percentile])
  end

  @doc """
  Computes Y-axis bounds for the climb chart, snapped to tier boundaries.

  Pads one tier below the minimum score and snaps the maximum up to the next
  tier boundary. Clamps to 0–120. Returns `{0, 120}` for nil inputs.
  """
  @spec chart_y_bounds(integer() | nil, integer() | nil) :: {integer(), integer()}
  def chart_y_bounds(nil, nil), do: {0, 120}

  def chart_y_bounds(min_score, max_score) do
    min_tier = div(min_score, 24) * 24
    y_min = max(min_tier - 24, 0)

    max_tier_base = div(max_score, 24) * 24

    y_max =
      if max_score > max_tier_base,
        do: min(max_tier_base + 24, 120),
        else: min(max_tier_base, 120)

    y_max = max(y_max, y_min + 24)

    {y_min, y_max}
  end

  @doc """
  Filters snapshots to a time range for chart display.

  - `"season"` — returns all snapshots (no filtering)
  - `"week"` — returns only snapshots from the last 7 days
  """
  @spec filter_snapshots_to_range([map()], String.t()) :: [map()]
  def filter_snapshots_to_range(snapshots, "season"), do: snapshots

  def filter_snapshots_to_range(snapshots, "week") do
    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)

    Enum.filter(snapshots, fn snapshot ->
      DateTime.compare(snapshot.occurred_at, cutoff) != :lt
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp class_to_index(class) do
    Enum.find_index(@class_order, &(&1 == class)) || 0
  end

  defp match_result_point(_ts, 0, 0), do: []

  defp match_result_point(ts, delta_wins, _delta_losses) when delta_wins > 0,
    do: [[DateTime.to_iso8601(ts), 1]]

  defp match_result_point(ts, _delta_wins, _delta_losses),
    do: [[DateTime.to_iso8601(ts), -1]]
end
