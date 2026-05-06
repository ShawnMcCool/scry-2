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

  # MTGA mastery curve: every tier costs the same XP. Mirrored in
  # Scry2Web.Components.MasteryCard.Helpers.xp_per_tier/0.
  @xp_per_tier 1_000

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

  @doc """
  Estimates which mastery tier the player will reach by season end at
  their current XP-per-day pace.

  Inputs are `Scry2.Collection.Snapshot{}` rows (or shaped like them)
  with `:occurred_at`, `:mastery_tier`, `:mastery_xp_in_tier`, and
  `:mastery_season_ends_at`. Total XP per snapshot is computed as
  `tier * 1000 + xp_in_tier`.

  Returns one of:
    * `%{xp_per_day, projected_tier_at_season_end, days_to_next_tier,
         season_ends_at}`
    * `:no_progress` when the rate is flat or negative
    * `:season_ended` when `now` is past `season_ends_at`
    * `:no_season_end` when the latest snapshot has no
      `mastery_season_ends_at`
    * `:insufficient_data` when fewer than two snapshots have mastery
      fields populated
  """
  @spec mastery_eta([map()], DateTime.t()) ::
          %{
            xp_per_day: float(),
            projected_tier_at_season_end: integer(),
            days_to_next_tier: float(),
            season_ends_at: DateTime.t()
          }
          | :no_progress
          | :season_ended
          | :no_season_end
          | :insufficient_data
  def mastery_eta(snapshots, %DateTime{} = now) do
    with_mastery =
      Enum.filter(snapshots, fn s ->
        is_integer(Map.get(s, :mastery_tier)) and
          is_integer(Map.get(s, :mastery_xp_in_tier))
      end)

    cond do
      length(with_mastery) < 2 ->
        :insufficient_data

      true ->
        first = List.first(with_mastery)
        last = List.last(with_mastery)
        ends_at = Map.get(last, :mastery_season_ends_at)

        first_xp = total_xp(first)
        last_xp = total_xp(last)
        seconds = DateTime.diff(last.occurred_at, first.occurred_at, :second)

        rate =
          if seconds == 0 do
            0.0
          else
            (last_xp - first_xp) / (seconds / 86_400)
          end

        cond do
          is_nil(ends_at) -> :no_season_end
          DateTime.compare(now, ends_at) == :gt -> :season_ended
          rate <= 0 -> :no_progress
          true -> compute_mastery_projection(last, rate, ends_at, now)
        end
    end
  end

  defp compute_mastery_projection(last, rate, ends_at, now) do
    last_xp = total_xp(last)
    days_remaining = DateTime.diff(ends_at, now, :second) / 86_400.0
    projected_xp = last_xp + rate * days_remaining
    projected_tier = trunc(projected_xp / @xp_per_tier)

    xp_to_next = @xp_per_tier - last.mastery_xp_in_tier
    days_to_next = xp_to_next / rate

    %{
      xp_per_day: rate,
      projected_tier_at_season_end: projected_tier,
      days_to_next_tier: days_to_next,
      season_ends_at: ends_at
    }
  end

  defp total_xp(%{mastery_tier: tier, mastery_xp_in_tier: xp})
       when is_integer(tier) and is_integer(xp),
       do: tier * @xp_per_tier + xp

  defp read_field(snapshot, field) do
    case Map.get(snapshot, field) do
      nil -> 0
      value -> value
    end
  end
end
