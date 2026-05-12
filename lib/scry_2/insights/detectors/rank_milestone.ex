defmodule Scry2.Insights.Detectors.RankMilestone do
  @moduledoc """
  Surfaces a recent rank-class promotion as a milestone.

  Tier 1 — reads `ranks_snapshots` ordered by `occurred_at`. For each
  format (constructed, limited), walks the timeline forward tracking the
  peak class seen so far and records every first-time promotion into a
  higher class.

  Bronze is treated as the starting floor — only crossings into Silver,
  Gold, Platinum, Diamond, or Mythic count. If a player decays out of a
  class and later re-reaches it, the original first-time snapshot is the
  one we report (re-climbs aren't milestones).

  Fires when the most-recent first-time promotion across both formats
  falls within the lookback window (default 14 days). If both formats
  have a fresh milestone, the higher class wins; ties break by most
  recent.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Ranks.Snapshot
  alias Scry2.Repo

  @class_order ~w(Bronze Silver Gold Platinum Diamond Mythic)
  @class_index Map.new(Enum.with_index(@class_order))
  @lookback_days 14

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    now = DateTime.utc_now()

    snapshots =
      Snapshot
      |> order_by([s], asc: s.occurred_at)
      |> Repo.all()

    constructed = first_time_promotions(snapshots, :constructed_class)
    limited = first_time_promotions(snapshots, :limited_class)

    case best_recent_milestone(constructed, limited, now) do
      nil -> nil
      milestone -> build_insight(milestone, constructed, limited, now)
    end
  end

  # Walks the snapshot stream and emits {class, occurred_at, season_ordinal}
  # for the first time each class above Bronze is reached.
  defp first_time_promotions(snapshots, class_field) do
    {_peak, promotions} =
      Enum.reduce(snapshots, {-1, []}, fn snapshot, {peak, acc} ->
        class = Map.fetch!(snapshot, class_field)
        index = class_index(class)

        cond do
          is_nil(index) ->
            {peak, acc}

          index > peak and index >= 1 ->
            {index,
             [
               %{
                 class: class,
                 class_index: index,
                 occurred_at: snapshot.occurred_at,
                 season_ordinal: snapshot.season_ordinal
               }
               | acc
             ]}

          index > peak ->
            {index, acc}

          true ->
            {peak, acc}
        end
      end)

    Enum.reverse(promotions)
  end

  defp best_recent_milestone(constructed, limited, now) do
    candidates =
      [
        latest_within_window(constructed, "constructed", now),
        latest_within_window(limited, "limited", now)
      ]
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] -> nil
      [one] -> one
      many -> Enum.max_by(many, &{&1.class_index, DateTime.to_unix(&1.occurred_at)})
    end
  end

  defp latest_within_window([], _format, _now), do: nil

  defp latest_within_window(promotions, format, now) do
    latest = List.last(promotions)
    days = DateTime.diff(now, latest.occurred_at, :second) |> div(86_400)

    if days <= @lookback_days do
      Map.merge(latest, %{format: format, days_ago: days})
    else
      nil
    end
  end

  defp build_insight(milestone, constructed, limited, _now) do
    promotions_this_season =
      promotions_in_season(constructed, milestone) +
        promotions_in_season(limited, milestone)

    %Insight{
      detector: "RankMilestone",
      surface: "home",
      tier: 1,
      title_template: "rank_milestone.title",
      body_template: "rank_milestone.body",
      stats: %{
        "primary" => %{"num" => milestone.class, "lbl" => "rank reached"},
        "secondary" => %{"num" => "#{milestone.days_ago}d ago", "lbl" => "achieved"},
        "tertiary" => %{"num" => milestone.format, "lbl" => "format"}
      },
      measurements: %{
        "class" => milestone.class,
        "class_index" => milestone.class_index,
        "format" => milestone.format,
        "reached_at" => DateTime.to_iso8601(milestone.occurred_at),
        "days_ago" => milestone.days_ago,
        "season_ordinal" => milestone.season_ordinal,
        "promotions_this_season" => promotions_this_season
      },
      sample_size: promotions_this_season,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp promotions_in_season(promotions, %{season_ordinal: season}) do
    Enum.count(promotions, &(&1.season_ordinal == season))
  end

  defp class_index(nil), do: nil
  defp class_index(class), do: Map.get(@class_index, class)
end
