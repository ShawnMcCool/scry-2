defmodule Scry2Web.MatchesHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.MatchesLive`. Extracted per
  ADR-013.
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

  @doc "Formats a UTC datetime for display in the match list."
  @spec format_started_at(DateTime.t() | nil) :: String.t()
  def format_started_at(nil), do: "—"

  def format_started_at(%DateTime{} = dt) do
    "#{pad(dt.year)}-#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)}"
  end

  @doc """
  Returns a human label for a match format string (e.g. `premier_draft`
  → `Premier Draft`).
  """
  @spec format_label(String.t() | nil) :: String.t()
  def format_label(nil), do: "—"

  def format_label(format) when is_binary(format) do
    format
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
