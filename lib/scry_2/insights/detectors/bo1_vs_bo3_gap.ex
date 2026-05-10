defmodule Scry2.Insights.Detectors.BO1VsBO3Gap do
  @moduledoc """
  Detects the gap between BO1 (single-game queues) and BO3 (Traditional)
  win rates.

  Tier 1 — pure SQL on `matches_matches.format_type` + `matches_matches.won`.
  BO3 is `format_type = "Traditional"`; BO1 is everything else with a
  recognised format. Returns an insight when both queues have meaningful
  samples and the gap exceeds a threshold.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_per_bucket 15
  @min_gap 0.05

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    rows =
      Match
      |> where(
        [m],
        not is_nil(m.won) and m.format_type in ["Constructed", "Traditional", "Limited"]
      )
      |> group_by([m], m.format_type)
      |> select([m], {
        m.format_type,
        count(m.id),
        sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))
      })
      |> Repo.all()

    aggregate_and_build(rows)
  end

  defp aggregate_and_build(rows) do
    {bo1_n, bo1_w, bo3_n, bo3_w} =
      Enum.reduce(rows, {0, 0, 0, 0}, fn {ft, n, w}, {b1n, b1w, b3n, b3w} ->
        n = n || 0
        w = to_int(w)

        case ft do
          "Traditional" -> {b1n, b1w, b3n + n, b3w + w}
          _ -> {b1n + n, b1w + w, b3n, b3w}
        end
      end)

    cond do
      bo1_n < @min_per_bucket ->
        nil

      bo3_n < @min_per_bucket ->
        nil

      true ->
        bo1_wr = bo1_w / bo1_n
        bo3_wr = bo3_w / bo3_n
        gap = bo1_wr - bo3_wr

        if abs(gap) < @min_gap do
          nil
        else
          build_insight(bo1_n, bo1_wr, bo3_n, bo3_wr, gap)
        end
    end
  end

  defp build_insight(bo1_n, bo1_wr, bo3_n, bo3_wr, gap) do
    total = bo1_n + bo3_n

    %Insight{
      detector: "BO1VsBO3Gap",
      surface: "home",
      tier: 1,
      title_template: "bo1_vs_bo3_gap.title",
      body_template: "bo1_vs_bo3_gap.body",
      stats: %{
        "primary" => %{"num" => format_pct(bo1_wr), "lbl" => "BO1"},
        "secondary" => %{"num" => format_pct(bo3_wr), "lbl" => "BO3"},
        "tertiary" => %{"num" => "n=#{total}", "lbl" => "matches"}
      },
      measurements: %{
        "bo1_wr" => bo1_wr,
        "bo1_n" => bo1_n,
        "bo3_wr" => bo3_wr,
        "bo3_n" => bo3_n,
        "total_n" => total,
        "gap" => gap
      },
      sample_size: total,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
