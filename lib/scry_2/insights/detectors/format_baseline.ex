defmodule Scry2.Insights.Detectors.FormatBaseline do
  @moduledoc """
  Surfaces your best-performing format with sample size.

  Tier 1 — pure SQL on `matches_matches.format_type` + `matches_matches.won`.
  Reports the format with the highest win rate among Constructed,
  Traditional, and Limited (each requiring a minimum sample). Returns
  `nil` if no format meets the threshold.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query
  import Scry2.Insights.Detectors.Numeric, only: [to_int: 1]

  alias Scry2.Insights.Insight
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_per_format 20

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
      |> Enum.map(fn {ft, n, w} -> %{format: ft, n: n || 0, w: to_int(w)} end)
      |> Enum.filter(&(&1.n >= @min_per_format))

    case rows do
      [] -> nil
      _ -> build_insight(rows)
    end
  end

  defp build_insight(rows) do
    rows = Enum.map(rows, &Map.put(&1, :wr, &1.w / &1.n))
    best = Enum.max_by(rows, & &1.wr)
    total = Enum.sum(Enum.map(rows, & &1.n))

    %Insight{
      detector: "FormatBaseline",
      surface: "home",
      tier: 1,
      title_template: "format_baseline.title",
      body_template: "format_baseline.body",
      stats: %{
        "primary" => %{"num" => format_pct(best.wr), "lbl" => human(best.format)},
        "secondary" => %{"num" => "#{best.n}", "lbl" => "matches"},
        "tertiary" => %{"num" => "of #{length(rows)}", "lbl" => "formats"}
      },
      measurements: %{
        "best_format" => best.format,
        "best_wr" => best.wr,
        "best_n" => best.n,
        "total_n" => total,
        "format_count" => length(rows),
        "rows" => Enum.map(rows, fn r -> %{"format" => r.format, "n" => r.n, "wr" => r.wr} end)
      },
      sample_size: total,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp human("Traditional"), do: "BO3"
  defp human("Constructed"), do: "BO1 Constructed"
  defp human("Limited"), do: "Limited"
  defp human(other), do: other

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
