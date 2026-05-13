defmodule Scry2.Insights.Detectors.DraftConversionRate do
  @moduledoc """
  Surfaces draft performance as average wins per completed run.

  Tier 1 — reads the last 10 completed drafts from `drafts_drafts` and
  reports average wins, trophy count (7-win runs), and sample size. Fires
  when at least 5 completed drafts are present.

  Drafts are infrequent enough that "last N runs" is a more meaningful
  lookback than "last 30 days" — five drafts in a slow month and ten in
  a busy one should both produce a stable signal.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Drafts.Draft
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  @window_size 10
  @min_drafts 5
  @trophy_threshold 7

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    drafts =
      Draft
      |> where(
        [d],
        not is_nil(d.completed_at) and not is_nil(d.wins) and not is_nil(d.losses)
      )
      |> order_by([d], desc: d.completed_at)
      |> limit(^@window_size)
      |> select([d], %{wins: d.wins, losses: d.losses})
      |> Repo.all()

    if length(drafts) < @min_drafts do
      nil
    else
      build_insight(drafts)
    end
  end

  defp build_insight(drafts) do
    n = length(drafts)
    total_wins = Enum.sum_by(drafts, & &1.wins)
    trophies = Enum.count(drafts, &(&1.wins >= @trophy_threshold))
    avg_wins = total_wins / n

    %Insight{
      detector: "DraftConversionRate",
      surface: "home",
      tier: 1,
      title_template: "draft_conversion_rate.title",
      body_template: "draft_conversion_rate.body",
      stats: %{
        "primary" => %{"num" => format_avg(avg_wins), "lbl" => "avg wins"},
        "secondary" => %{"num" => Integer.to_string(trophies), "lbl" => "trophies"},
        "tertiary" => %{"num" => "#{n}", "lbl" => "drafts"}
      },
      measurements: %{
        "avg_wins" => avg_wins,
        "total_wins" => total_wins,
        "trophies" => trophies,
        "drafts_n" => n,
        "window_size" => @window_size
      },
      sample_size: n,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_avg(avg) when is_float(avg), do: :erlang.float_to_binary(avg, decimals: 1)
end
