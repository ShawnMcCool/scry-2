defmodule Scry2.Analytics.WinRate do
  @moduledoc """
  Shared win-rate computation.

  Win rates appear in many surfaces — overall stats, per-format
  breakdowns, per-card metrics, rolling time-series — and used to
  drift between implementations: some rounded, some returned nil,
  some treated zero-total as `0.0`. This module is the single source
  of truth so consumers can rely on consistent rounding and nil
  semantics.
  """

  @doc """
  Compute a win rate as a percent (0.0–100.0) rounded to `precision`
  decimal places. Returns `nil` when `total` is zero — the absence of
  a denominator is a meaningful distinct value from a 0% win rate.

  ## Examples

      iex> Scry2.Analytics.WinRate.percent(5, 10)
      50.0

      iex> Scry2.Analytics.WinRate.percent(7, 10, 2)
      70.0

      iex> Scry2.Analytics.WinRate.percent(0, 0)
      nil
  """
  @spec percent(integer() | nil, integer() | nil, non_neg_integer()) :: float() | nil
  def percent(wins, total, precision \\ 1)
  def percent(_wins, nil, _precision), do: nil
  def percent(_wins, 0, _precision), do: nil
  def percent(nil, _total, _precision), do: 0.0

  def percent(wins, total, precision)
      when is_integer(wins) and is_integer(total) and total > 0 do
    Float.round(wins / total * 100, precision)
  end
end
