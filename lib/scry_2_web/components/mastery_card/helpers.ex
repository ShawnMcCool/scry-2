defmodule Scry2Web.Components.MasteryCard.Helpers do
  @moduledoc """
  Pure formatters for `Scry2Web.Components.MasteryCard`. Extracted per
  ADR-013 so the card stays thin and the formatters get standalone
  tests with `async: true` and no DB.
  """

  @xp_per_tier 1_000

  @doc """
  XP-in-tier as a percentage of the per-tier interval, clamped to
  [0.0, 100.0]. The per-tier XP requirement is 1000 on MTGA's mastery
  curve.
  """
  @spec xp_progress_percent(integer() | nil) :: float()
  def xp_progress_percent(nil), do: 0.0

  def xp_progress_percent(xp_in_tier) when is_integer(xp_in_tier) do
    pct = xp_in_tier / @xp_per_tier * 100.0
    pct |> max(0.0) |> min(100.0) |> Float.round(1)
  end

  @doc """
  Format the tier as a player-facing label.
  """
  @spec format_tier(integer() | nil) :: String.t()
  def format_tier(nil), do: "—"
  def format_tier(tier) when is_integer(tier), do: "Tier #{tier}"

  @doc """
  Format season end as a relative countdown: "Ends today" / "Ends
  tomorrow" / "Ends in N days" / "Season ended" / "" when nil.
  """
  @spec season_end_countdown(DateTime.t() | nil, DateTime.t()) :: String.t()
  def season_end_countdown(nil, _now), do: ""

  def season_end_countdown(%DateTime{} = ends_at, %DateTime{} = now) do
    days = DateTime.diff(ends_at, now, :second) / 86_400

    cond do
      days < 0.0 -> "Season ended"
      days < 1.0 -> "Ends today"
      days < 1.5 -> "Ends tomorrow"
      true -> "Ends in #{round(days)} days"
    end
  end

  @doc """
  Parses MTGA's mastery season identifier into a set code suitable for
  `<.set_icon code="...">`. MTGA uses `BattlePass_<SET>` (e.g.
  `BattlePass_SOS` → `"SOS"`). Falls back to nil for unrecognised shapes
  so the caller can suppress the icon.
  """
  @spec set_code_from_season_name(String.t() | nil) :: String.t() | nil
  def set_code_from_season_name(nil), do: nil

  def set_code_from_season_name("BattlePass_" <> code) when byte_size(code) > 0,
    do: String.upcase(code)

  def set_code_from_season_name(_), do: nil

  @doc """
  One-line summary: "Tier 12 · Ends in 12 days" — drops empty pieces.
  """
  @spec summary_line(integer() | nil, DateTime.t() | nil, DateTime.t()) :: String.t()
  def summary_line(tier, ends_at, now) do
    [
      format_tier(tier),
      season_end_countdown(ends_at, now) |> emptyish_to_nil()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Per-tier XP requirement on MTGA's mastery curve."
  @spec xp_per_tier() :: pos_integer()
  def xp_per_tier, do: @xp_per_tier

  @doc """
  Renders a `Scry2.Economy.Forecast.mastery_eta/2` result as a one-line
  player-facing label, e.g. `"+714 XP/day · projected Tier 56 by season
  end"`. Atom variants render an empty string so the caller can suppress
  the line entirely.
  """
  @spec forecast_label(map() | atom() | nil) :: String.t()
  def forecast_label(%{xp_per_day: rate, projected_tier_at_season_end: tier})
      when is_number(rate) and is_integer(tier) do
    "+#{format_thousands(round(rate))} XP/day · projected Tier #{tier} by season end"
  end

  def forecast_label(_), do: ""

  defp format_thousands(n) when is_integer(n) and n < 0,
    do: "-" <> format_thousands(-n)

  defp format_thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp emptyish_to_nil(""), do: nil
  defp emptyish_to_nil(string), do: string
end
