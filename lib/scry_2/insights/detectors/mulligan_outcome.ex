defmodule Scry2.Insights.Detectors.MulliganOutcome do
  @moduledoc """
  Detects the gap between win rate on a kept opening hand vs at least
  one mulligan.

  Tier 1 — pure SQL on `matches_matches.total_mulligans` + `matches_matches.won`.
  Buckets into "no mulligans" and "one or more mulligans". Returns an
  insight when both buckets meet a minimum size and the gap is meaningful.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_n 30
  @min_per_bucket 5
  @min_gap 0.08

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    rows =
      Match
      |> where([m], not is_nil(m.total_mulligans) and not is_nil(m.won))
      |> select([m], {m.total_mulligans, m.won})
      |> Repo.all()

    total_n = length(rows)

    if total_n < @min_n do
      nil
    else
      bucketize_and_build(rows, total_n)
    end
  end

  defp bucketize_and_build(rows, total_n) do
    {kept_n, kept_w, mull_n, mull_w} =
      Enum.reduce(rows, {0, 0, 0, 0}, fn
        {0, true}, {kn, kw, mn, mw} -> {kn + 1, kw + 1, mn, mw}
        {0, false}, {kn, kw, mn, mw} -> {kn + 1, kw, mn, mw}
        {_, true}, {kn, kw, mn, mw} -> {kn, kw, mn + 1, mw + 1}
        {_, false}, {kn, kw, mn, mw} -> {kn, kw, mn + 1, mw}
      end)

    cond do
      kept_n < @min_per_bucket ->
        nil

      mull_n < @min_per_bucket ->
        nil

      true ->
        kept_wr = kept_w / kept_n
        mull_wr = mull_w / mull_n
        gap = kept_wr - mull_wr

        if abs(gap) < @min_gap do
          nil
        else
          build_insight(kept_n, kept_wr, mull_n, mull_wr, total_n, gap)
        end
    end
  end

  defp build_insight(kept_n, kept_wr, mull_n, mull_wr, total_n, gap) do
    %Insight{
      detector: "MulliganOutcome",
      surface: "home",
      tier: 1,
      title_template: "mulligan_outcome.title",
      body_template: "mulligan_outcome.body",
      stats: %{
        "primary" => %{"num" => format_pct(kept_wr), "lbl" => "kept"},
        "secondary" => %{"num" => format_pct(mull_wr), "lbl" => "mulled"},
        "tertiary" => %{"num" => "#{total_n}", "lbl" => "matches"}
      },
      measurements: %{
        "kept_wr" => kept_wr,
        "kept_n" => kept_n,
        "mull_wr" => mull_wr,
        "mull_n" => mull_n,
        "total_n" => total_n,
        "gap" => gap
      },
      sample_size: total_n,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
