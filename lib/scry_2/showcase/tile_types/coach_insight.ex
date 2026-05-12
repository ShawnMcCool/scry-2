defmodule Scry2.Showcase.TileTypes.CoachInsight do
  @moduledoc """
  γ mini-page tile that wraps any persisted `%Insight{}`.

  The universal coach tile — every detector that produces a homepage
  insight can be rendered through this tile type. Title and body are
  rendered from the insight's `:title_template` / `:body_template` via
  `Scry2.Showcase.Templates`. Stats row is taken directly from
  `insight.stats`. The meta line carries sample size, confidence (if
  present), and freshness — all visible facts about the measurement.

  Detector-specific tile types may exist later if they need richer art
  (e.g. a deck-heater chart or a milestone rank icon).
  """

  alias Scry2.Insights.Insight
  alias Scry2.Showcase.{Templates, TileSpec}

  @spec build(Insight.t()) :: TileSpec.t()
  def build(%Insight{} = insight) do
    %TileSpec{
      kind: :coach_insight,
      kind_label: label_for_detector(insight.detector),
      composition: :insight,
      title: Templates.render_title(insight),
      body: Templates.render_body(insight),
      stats: stats_list(insight.stats),
      meta: meta(insight),
      target: {:navigate, "/insights/#{insight.id}"},
      badge: badge_for_tier(insight.tier)
    }
  end

  defp label_for_detector("OnPlayVsOnDraw"), do: "play vs draw"
  defp label_for_detector("MulliganOutcome"), do: "mulligan tax"
  defp label_for_detector("BO1VsBO3Gap"), do: "BO1 vs BO3"
  defp label_for_detector("P1P1RarityCorrelation"), do: "draft signal"
  defp label_for_detector("FormatBaseline"), do: "your formats"
  defp label_for_detector("CraftingVelocity"), do: "this week's crafting"
  defp label_for_detector("EventROI"), do: "this week's economy"
  defp label_for_detector("DeckHeater"), do: "deck on a heater"
  defp label_for_detector("DeckColorOutlier"), do: "color combo"
  defp label_for_detector("RankMilestone"), do: "rank milestone"
  defp label_for_detector("DraftConversionRate"), do: "draft conversion"
  defp label_for_detector("WeekendWarrior"), do: "play schedule"
  defp label_for_detector("ComebackArtist"), do: "BO3 resilience"
  defp label_for_detector(_), do: "pattern noticed"

  defp stats_list(stats) when is_map(stats) do
    [stats["primary"], stats["secondary"], stats["tertiary"]]
    |> Enum.reject(&is_nil/1)
  end

  defp stats_list(_), do: []

  defp meta(%Insight{} = insight) do
    [
      sample_size_meta(insight.sample_size),
      confidence_meta(insight.confidence),
      age_meta(insight.computed_at)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp sample_size_meta(nil), do: nil
  defp sample_size_meta(n) when is_integer(n), do: "n=#{n}"

  defp confidence_meta(nil), do: nil
  defp confidence_meta(p) when is_number(p) and p < 0.001, do: "p<0.001"

  defp confidence_meta(p) when is_number(p),
    do: "p=" <> :erlang.float_to_binary(p, decimals: 3)

  defp age_meta(nil), do: nil

  defp age_meta(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 3600 -> "fresh"
      diff < 86_400 -> "today"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d old"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  defp badge_for_tier(2), do: :tier_2
  defp badge_for_tier(_), do: nil
end
