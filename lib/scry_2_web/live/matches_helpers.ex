defmodule Scry2Web.MatchesHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.MatchesLive`. Extracted per
  ADR-013.

  Shared formatters (`format_datetime/1`, `format_label/1`) live in
  `Scry2Web.LiveHelpers`.
  """

  @doc "Returns a badge class for the win/loss state."
  @spec result_class(boolean() | nil) :: String.t()
  def result_class(true), do: "badge-success"
  def result_class(false), do: "badge-error"
  def result_class(nil), do: "badge-ghost"

  @doc "Returns a human label for the win/loss state."
  @spec result_label(boolean() | nil) :: String.t()
  def result_label(true), do: "Won"
  def result_label(false), do: "Lost"
  def result_label(nil), do: "—"
end
