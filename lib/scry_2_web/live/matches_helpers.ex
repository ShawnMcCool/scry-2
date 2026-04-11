defmodule Scry2Web.MatchesHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.MatchesLive`. Extracted per
  ADR-013.

  Shared formatters (`format_datetime/1`, `format_label/1`) live in
  `Scry2Web.LiveHelpers`.
  """

  @doc "Returns a badge class for the win/loss state (UIDR-008)."
  @spec result_class(boolean() | nil) :: String.t()
  def result_class(true), do: "badge-soft badge-success"
  def result_class(false), do: "badge-soft badge-error"
  def result_class(nil), do: "badge-ghost"

  @doc "Returns a human label for the win/loss state."
  @spec result_label(boolean() | nil) :: String.t()
  def result_label(true), do: "Won"
  def result_label(false), do: "Lost"
  def result_label(nil), do: "—"

  @doc """
  Returns the single result letter for a match: "W", "L", or "—".
  """
  @spec result_letter(boolean() | nil) :: String.t()
  def result_letter(true), do: "W"
  def result_letter(false), do: "L"
  def result_letter(nil), do: "—"

  @doc """
  Returns a Tailwind text-color class for the result letter.
  Green for win, red for loss, muted for unknown.
  """
  @spec result_letter_class(boolean() | nil) :: String.t()
  def result_letter_class(true), do: "text-emerald-400"
  def result_letter_class(false), do: "text-red-400"
  def result_letter_class(nil), do: "text-base-content/30"

  @doc """
  Formats a DateTime for display in the matches list row.

  Examples:
      format_match_datetime(~U[2026-04-06 19:36:00Z]) => "Apr 06 · 19:36"
  """
  @spec format_match_datetime(DateTime.t() | nil) :: String.t()
  def format_match_datetime(nil), do: "—"

  def format_match_datetime(%DateTime{} = dt) do
    month = month_abbr(dt.month)
    day = dt.day |> Integer.to_string() |> String.pad_leading(2, "0")
    hour = dt.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = dt.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{month} #{day} · #{hour}:#{minute}"
  end

  @doc """
  Extracts a "W-L" game score string from a match listing's `game_results` map.

  Returns "—" when data is unavailable.
  """
  @spec game_score(map() | nil, boolean() | nil) :: String.t()
  def game_score(nil, _won), do: "—"

  def game_score(%{"results" => results}, _won) when is_list(results) do
    wins = Enum.count(results, & &1["won"])
    losses = Enum.count(results, &(&1["won"] == false))
    "#{wins}–#{losses}"
  end

  def game_score(_game_results, _won), do: "—"

  @doc """
  Returns a short label for on_play status.
  "Play" when on the play, "Draw" when on the draw, "—" when unknown.
  """
  @spec on_play_label(boolean() | nil) :: String.t()
  def on_play_label(true), do: "Play"
  def on_play_label(false), do: "Draw"
  def on_play_label(nil), do: "—"

  # ── Internals ───────────────────────────────────────────────────────────

  defp month_abbr(1), do: "Jan"
  defp month_abbr(2), do: "Feb"
  defp month_abbr(3), do: "Mar"
  defp month_abbr(4), do: "Apr"
  defp month_abbr(5), do: "May"
  defp month_abbr(6), do: "Jun"
  defp month_abbr(7), do: "Jul"
  defp month_abbr(8), do: "Aug"
  defp month_abbr(9), do: "Sep"
  defp month_abbr(10), do: "Oct"
  defp month_abbr(11), do: "Nov"
  defp month_abbr(12), do: "Dec"
end
