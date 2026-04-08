defmodule Scry2Web.StatsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.StatsLive`. Extracted per ADR-013.
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
end
