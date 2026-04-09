defmodule Scry2Web.RanksHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.RanksLive`. Extracted per ADR-013.
  """

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

  # ── Private ──────────────────────────────────────────────────────────

  @class_order ~w(Bronze Silver Gold Platinum Diamond)

  defp class_to_index(class) do
    Enum.find_index(@class_order, &(&1 == class)) || 0
  end
end
