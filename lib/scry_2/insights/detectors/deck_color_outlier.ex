defmodule Scry2.Insights.Detectors.DeckColorOutlier do
  @moduledoc """
  Detects a player-deck color combination whose win rate diverges
  significantly from the player's overall baseline.

  Tier 2 — uses `Scry2.Insights.Significance.z_test_proportions/4` to
  reject color combos whose results are plausibly variance. Requires a
  minimum sample per combo and an overall baseline. Returns the most
  significant outlier (above OR below baseline), or `nil`.

  Note: `matches.deck_colors` is the *player's* deck color string, not
  the opponent's. We don't capture opponent deck colors. This detector
  surfaces variance in your own deck choices, not matchup data.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query
  import Scry2.Insights.Detectors.Numeric, only: [to_int: 1]

  alias Scry2.Insights.{Insight, Significance}
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_combo_matches 12
  @min_baseline 50
  @max_p_value 0.05

  @impl true
  def tier, do: 2

  @impl true
  def detect(_opts) do
    case baseline_wr() do
      nil ->
        nil

      {b_wr, b_n} ->
        per_combo_stats()
        |> Enum.filter(&(&1.n >= @min_combo_matches))
        |> annotate(b_wr, b_n)
        |> pick_best_outlier(b_wr, b_n)
    end
  end

  defp baseline_wr do
    {n, w} =
      Match
      |> where([m], not is_nil(m.won) and not is_nil(m.deck_colors) and m.deck_colors != "")
      |> select([m], {count(m.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))})
      |> Repo.one()

    n = n || 0
    w = to_int(w)

    if n < @min_baseline, do: nil, else: {w / n, n}
  end

  defp per_combo_stats do
    Match
    |> where([m], not is_nil(m.won) and not is_nil(m.deck_colors) and m.deck_colors != "")
    |> group_by([m], m.deck_colors)
    |> select([m], %{
      colors: m.deck_colors,
      n: count(m.id),
      w: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      n = row.n || 0
      w = to_int(row.w)
      Map.merge(row, %{n: n, w: w, wr: if(n > 0, do: w / n, else: 0.0)})
    end)
  end

  defp annotate(rows, b_wr, b_n) do
    Enum.map(rows, fn row ->
      p = Significance.z_test_proportions(row.wr, row.n, b_wr, b_n)
      Map.put(row, :p_value, p)
    end)
  end

  defp pick_best_outlier(rows, b_wr, b_n) do
    rows
    |> Enum.filter(&qualifying_outlier?/1)
    |> case do
      [] ->
        nil

      outliers ->
        best = Enum.min_by(outliers, &p_value_for_sort/1)
        build_insight(best, b_wr, b_n)
    end
  end

  defp qualifying_outlier?(%{p_value: p}) when is_float(p) and p < @max_p_value, do: true
  defp qualifying_outlier?(_), do: false

  defp p_value_for_sort(%{p_value: p}) when is_float(p), do: p
  defp p_value_for_sort(_), do: 1.0

  defp build_insight(combo, b_wr, b_n) do
    above? = combo.wr > b_wr
    direction = if above?, do: "above", else: "below"

    %Insight{
      detector: "DeckColorOutlier",
      surface: "home",
      tier: 2,
      title_template: "deck_color_outlier.title",
      body_template: "deck_color_outlier.body",
      stats: %{
        "primary" => %{"num" => format_pct(combo.wr), "lbl" => combo.colors},
        "secondary" => %{"num" => format_pct(b_wr), "lbl" => "baseline"},
        "tertiary" => %{"num" => "#{combo.n}", "lbl" => "matches"}
      },
      measurements: %{
        "colors" => combo.colors,
        "combo_wr" => combo.wr,
        "combo_n" => combo.n,
        "baseline_wr" => b_wr,
        "baseline_n" => b_n,
        "p_value" => combo.p_value,
        "direction" => direction
      },
      sample_size: combo.n,
      confidence: combo.p_value,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
