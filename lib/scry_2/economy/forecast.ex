defmodule Scry2.Economy.Forecast do
  @moduledoc """
  Pure forecasting helpers over an inventory-snapshot stream.

  Inputs are lists of maps (or `%InventorySnapshot{}` structs) with
  `:occurred_at` and the queried field (`:gold`, `:gems`,
  `:wildcards_*`, `:vault_progress`). The list must be ordered
  ascending by `:occurred_at` — the same order
  `Scry2.Economy.list_inventory_snapshots/1` and
  `Scry2.Economy.EconomyHelpers.filter_snapshots_to_range/2` produce.

  The functions here treat the snapshot stream as a discrete time
  series and compute simple linear extrapolations. No smoothing, no
  outlier rejection, no per-source attribution — that lives in the
  projections that produce the snapshots.
  """

  @type field :: atom()

  @doc """
  Net change in `field` between the first and last snapshots in the
  list. Treats nil values as zero. Returns 0 with fewer than two
  snapshots.
  """
  @spec net_change([map()], field()) :: integer() | float()
  def net_change(snapshots, _field) when length(snapshots) < 2, do: 0

  def net_change(snapshots, field) do
    first = List.first(snapshots) |> read_field(field)
    last = List.last(snapshots) |> read_field(field)
    last - first
  end

  @doc """
  Average daily change in `field` across the snapshot window
  (timestamp of last - first). Returns 0.0 when fewer than two
  snapshots, or when the window has zero duration.
  """
  @spec daily_rate([map()], field()) :: float()
  def daily_rate(snapshots, _field) when length(snapshots) < 2, do: 0.0

  def daily_rate(snapshots, field) do
    first = List.first(snapshots)
    last = List.last(snapshots)
    delta = read_field(last, field) - read_field(first, field)
    seconds = DateTime.diff(last.occurred_at, first.occurred_at, :second)

    if seconds == 0 do
      0.0
    else
      days = seconds / 86_400
      delta / days
    end
  end

  @doc """
  Estimates when `vault_progress` will reach 100% at the current rate.

  Returns one of:
    * `%{eta: DateTime.t(), days: float(), rate_per_day: float()}`
    * `:already_full` when the latest snapshot is at or above 100
    * `:no_progress` when vault_progress is flat or decreasing
    * `:insufficient_data` when fewer than two snapshots have a numeric
      vault_progress value
  """
  @spec vault_eta([map()], DateTime.t()) ::
          %{eta: DateTime.t(), days: float(), rate_per_day: float()}
          | :already_full
          | :no_progress
          | :insufficient_data
  def vault_eta(snapshots, %DateTime{} = now) do
    with_progress =
      snapshots
      |> Enum.filter(&is_number(Map.get(&1, :vault_progress)))

    cond do
      length(with_progress) < 2 ->
        :insufficient_data

      true ->
        first = List.first(with_progress)
        last = List.last(with_progress)
        latest_pct = read_field(last, :vault_progress)
        rate = daily_rate(with_progress, :vault_progress)

        cond do
          latest_pct >= 100.0 -> :already_full
          rate <= 0 -> :no_progress
          true -> compute_eta(latest_pct, rate, last.occurred_at, now, first)
        end
    end
  end

  defp compute_eta(latest_pct, rate, last_ts, now, _first) do
    remaining = 100.0 - latest_pct
    days_from_last = remaining / rate
    eta = DateTime.add(last_ts, round(days_from_last * 86_400), :second)
    days_from_now = DateTime.diff(eta, now, :second) / 86_400.0
    %{eta: eta, days: days_from_now, rate_per_day: rate}
  end

  defp read_field(snapshot, field) do
    case Map.get(snapshot, field) do
      nil -> 0
      value -> value
    end
  end
end
