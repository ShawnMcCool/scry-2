defmodule Scry2.Insights.Detectors.WeekendWarrior do
  @moduledoc """
  Surfaces a weekend-vs-weekday play concentration when it deviates
  meaningfully from the uniform 2/7 baseline.

  Tier 1 — pure SQL over `matches_matches.started_at`. SQLite's
  `strftime('%w', ...)` returns the day of week as 0–6 (Sunday=0,
  Saturday=6); the detector buckets each match into "weekend" (0 or 6)
  or "weekday" and reports the weekend share.

  Fires only when there are at least 50 valid matches and the weekend
  share is either ≥ 50% (clearly weekend-focused) or ≤ 15% (clearly
  weeknight-focused). The neutral band around 28.6% (= 2/7) is not
  surfaced — it carries no information.

  Day-of-week is computed in UTC because that's what `started_at`
  stores. Players in distant time zones will see some weekend-evening
  play attributed to Monday or vice-versa; the bias is small for most
  players and the alternative (carrying timezone metadata on every
  match) isn't worth it for v1.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_total 50
  @high_threshold 0.50
  @low_threshold 0.15

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    {weekend_n, weekday_n} =
      Match
      |> where([m], not is_nil(m.won) and not is_nil(m.started_at))
      |> select([m], {
        sum(
          fragment(
            "CASE WHEN strftime('%w', ?) IN ('0', '6') THEN 1 ELSE 0 END",
            m.started_at
          )
        ),
        sum(
          fragment(
            "CASE WHEN strftime('%w', ?) IN ('0', '6') THEN 0 ELSE 1 END",
            m.started_at
          )
        )
      })
      |> Repo.one()
      |> case do
        {nil, nil} -> {0, 0}
        {we, wd} -> {to_int(we), to_int(wd)}
      end

    total = weekend_n + weekday_n

    cond do
      total < @min_total ->
        nil

      true ->
        share = weekend_n / total

        cond do
          share >= @high_threshold -> build_insight(:weekend, weekend_n, weekday_n, share)
          share <= @low_threshold -> build_insight(:weeknight, weekend_n, weekday_n, share)
          true -> nil
        end
    end
  end

  defp build_insight(direction, weekend_n, weekday_n, share) do
    total = weekend_n + weekday_n

    primary_pct =
      case direction do
        :weekend -> share
        :weeknight -> 1 - share
      end

    %Insight{
      detector: "WeekendWarrior",
      surface: "home",
      tier: 1,
      title_template: "weekend_warrior.title",
      body_template: "weekend_warrior.body",
      stats: %{
        "primary" => %{"num" => format_pct(primary_pct), "lbl" => label_for(direction)},
        "secondary" => %{"num" => "n=#{total}", "lbl" => "matches"},
        "tertiary" => %{"num" => "uniform 29%", "lbl" => "baseline"}
      },
      measurements: %{
        "direction" => Atom.to_string(direction),
        "weekend_n" => weekend_n,
        "weekday_n" => weekday_n,
        "total_n" => total,
        "weekend_share" => share
      },
      sample_size: total,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp label_for(:weekend), do: "weekend"
  defp label_for(:weeknight), do: "weeknight"

  defp format_pct(rate), do: "#{round(rate * 100)}%"

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
end
