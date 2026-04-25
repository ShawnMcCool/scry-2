defmodule Scry2Web.CollectionDiagnosticsHelpers do
  @moduledoc """
  Pure helpers for `Scry2Web.CollectionDiagnosticsLive`. Extracted per
  ADR-013 so chart series, ratios, and number formatting are unit-testable
  without touching the database or LiveView.
  """

  @doc """
  Builds the acquired/removed bar series from a list of `%Diff{}` rows.

  Result shape (consumed by the `reconciliation_activity` chart hook):

      %{
        acquired: [[iso8601, total_acquired], ...],
        removed:  [[iso8601, total_removed],  ...]
      }

  Sorted oldest-first so ECharts' time axis renders left-to-right.
  """
  @spec activity_series([map()]) :: %{acquired: list(), removed: list()}
  def activity_series(diffs) do
    sorted = Enum.sort_by(diffs, & &1.inserted_at, DateTime)

    %{
      acquired:
        Enum.map(sorted, fn diff ->
          [DateTime.to_iso8601(diff.inserted_at), diff.total_acquired]
        end),
      removed:
        Enum.map(sorted, fn diff ->
          [DateTime.to_iso8601(diff.inserted_at), diff.total_removed]
        end)
    }
  end

  @doc """
  Builds the cumulative collection-size series from a list of
  `%Snapshot{}` rows. Each point is `[iso8601, total_copies]`.
  """
  @spec growth_series([map()]) :: [[String.t() | non_neg_integer()]]
  def growth_series(snapshots) do
    snapshots
    |> Enum.sort_by(& &1.snapshot_ts, DateTime)
    |> Enum.map(fn snapshot ->
      [DateTime.to_iso8601(snapshot.snapshot_ts), snapshot.total_copies]
    end)
  end

  @doc """
  Builds the refresh-attempt timeline as a list of dot points. Each
  point carries the snapshot timestamp and reader confidence tag so
  the chart hook can color walker vs fallback_scan dots differently.
  """
  @spec refresh_dots_series([map()]) :: [%{ts: String.t(), confidence: String.t()}]
  def refresh_dots_series(snapshots) do
    snapshots
    |> Enum.sort_by(& &1.snapshot_ts, DateTime)
    |> Enum.map(fn snapshot ->
      %{
        ts: DateTime.to_iso8601(snapshot.snapshot_ts),
        confidence: snapshot.reader_confidence
      }
    end)
  end

  @doc """
  Returns the share of diffs that recorded an actual change (1.0 = every
  diff was informative; 0.0 = every diff was empty noise). Returns `nil`
  when there are no diffs to avoid divide-by-zero.
  """
  @spec noise_signal_ratio(non_neg_integer(), non_neg_integer()) :: float() | nil
  def noise_signal_ratio(0, _empty), do: nil

  def noise_signal_ratio(total, empty) when total > 0 do
    Float.round((total - empty) / total, 2)
  end

  @doc """
  Returns the share of snapshots taken via the walker (high-confidence)
  path vs the structural fallback scan, as a `0..1` float rounded to 2
  decimals. Returns `nil` when there are no snapshots in either bucket
  (divide-by-zero). Input matches `Scry2.Collection.reader_path_breakdown/0`.
  """
  @spec walker_share(%{walker: non_neg_integer(), fallback_scan: non_neg_integer()}) ::
          float() | nil
  def walker_share(%{walker: 0, fallback_scan: 0}), do: nil

  def walker_share(%{walker: walker, fallback_scan: fallback}) do
    Float.round(walker / (walker + fallback), 2)
  end

  @doc "Formats a `0..1` float as a rounded percent string (e.g. `0.7 -> \"70%\"`)."
  @spec format_percent(float() | nil) :: String.t()
  def format_percent(nil), do: "—"
  def format_percent(value) when is_float(value), do: "#{round(value * 100)}%"

  @doc "Formats an integer with comma separators."
  @spec format_count(integer()) :: String.t()
  def format_count(n) when is_integer(n) and n < 0, do: "-" <> format_count(-n)

  def format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
