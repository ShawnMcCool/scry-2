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
end
