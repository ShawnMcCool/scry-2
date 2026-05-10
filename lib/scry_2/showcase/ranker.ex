defmodule Scry2.Showcase.Ranker do
  @moduledoc """
  Scores insight candidates for the Showcase homepage.

      score = significance × novelty × recency

  - **Significance** — larger sample size and lower p-value (when present)
    earn a higher score. Tier-2 detectors with significant p-values get
    a 1.5× bonus over Tier-1 base.
  - **Novelty** — insights the user hasn't seen, or has seen rarely,
    score higher than insights they've already absorbed.
  - **Recency** — fresher computations (within 24h) score full; older
    insights decay, since the data they describe may be stale.

  Pure functions. The Homepage selector calls `score/1` per candidate
  and picks the top N.
  """

  alias Scry2.Insights.Insight

  @doc "Returns a non-negative float score for ranking against other insights."
  @spec score(Insight.t(), DateTime.t()) :: float()
  def score(%Insight{} = insight, now \\ DateTime.utc_now()) do
    significance(insight) * novelty(insight) * recency(insight, now)
  end

  defp significance(%Insight{sample_size: n, confidence: p}) do
    base = min(n || 0, 200) / 200

    if is_number(p) and p < 0.05 do
      base * 1.5
    else
      base
    end
  end

  defp novelty(%Insight{shown_count: count}) do
    case count || 0 do
      0 -> 1.0
      1 -> 0.7
      n when n < 5 -> 0.4
      _ -> 0.1
    end
  end

  defp recency(%Insight{computed_at: nil}, _now), do: 0.0

  defp recency(%Insight{computed_at: dt}, now) do
    age_seconds = DateTime.diff(now, dt, :second)
    age_days = age_seconds / 86_400

    cond do
      age_days < 1 -> 1.0
      age_days < 3 -> 0.6
      age_days < 7 -> 0.3
      true -> 0.1
    end
  end
end
