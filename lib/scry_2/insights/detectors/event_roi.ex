defmodule Scry2.Insights.Detectors.EventROI do
  @moduledoc """
  Detects the event type with the worst net-gem flow over the lookback
  window.

  Tier 1 — pure SQL on `economy_event_entries`. Fires when at least one
  event type has a negative net flow over `@lookback_days` and the count
  of events for that type meets `@min_events`. Returns `nil` if every
  event type is gem-positive.

  Only events with `entry_currency_type = "gems"` are considered, since
  cross-currency comparisons are ambiguous.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query
  import Scry2.Insights.Detectors.Numeric, only: [to_int: 1]

  alias Scry2.Economy.EventEntry
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  @lookback_days 30
  @min_events 3

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@lookback_days, :day)

    case worst_event_type(cutoff) do
      nil -> nil
      row -> build_insight(row)
    end
  end

  defp worst_event_type(cutoff) do
    EventEntry
    |> where(
      [e],
      e.entry_currency_type == "gems" and
        not is_nil(e.claimed_at) and
        e.joined_at >= ^cutoff
    )
    |> group_by([e], e.event_type)
    |> select([e], %{
      event_type: e.event_type,
      count: count(e.id),
      spent: sum(coalesce(e.entry_fee, 0)),
      earned: sum(coalesce(e.gems_awarded, 0))
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      spent = to_int(row.spent)
      earned = to_int(row.earned)
      Map.merge(row, %{spent: spent, earned: earned, net: earned - spent})
    end)
    |> Enum.filter(fn row -> row.count >= @min_events and row.net < 0 end)
    |> Enum.min_by(& &1.net, fn -> nil end)
  end

  defp build_insight(%{
         event_type: type,
         count: n,
         spent: spent,
         earned: earned,
         net: net
       }) do
    roi = if spent > 0, do: net / spent, else: 0.0

    %Insight{
      detector: "EventROI",
      surface: "home",
      tier: 1,
      title_template: "event_roi.title",
      body_template: "event_roi.body",
      stats: %{
        "primary" => %{"num" => "#{net}", "lbl" => "net gems"},
        "secondary" => %{"num" => format_pct(roi), "lbl" => "ROI"},
        "tertiary" => %{"num" => "#{n}", "lbl" => "events"}
      },
      measurements: %{
        "event_type" => type,
        "lookback_days" => @lookback_days,
        "events_count" => n,
        "gems_spent" => spent,
        "gems_earned" => earned,
        "net_gems" => net,
        "roi" => roi
      },
      sample_size: n,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_pct(rate) do
    sign = if rate >= 0, do: "+", else: ""
    "#{sign}#{round(rate * 100)}%"
  end
end
