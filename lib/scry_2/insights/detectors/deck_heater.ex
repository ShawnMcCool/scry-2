defmodule Scry2.Insights.Detectors.DeckHeater do
  @moduledoc """
  Detects a deck whose 7-day rolling win rate is significantly above
  the player's overall baseline.

  Tier 2 — uses `Scry2.Insights.Significance.z_test_proportions/4` to
  reject decks whose hot streak could plausibly be variance. Requires a
  minimum number of recent matches per deck and a meaningful effect
  size. Returns the most-significant heater, or `nil`.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.{Insight, Significance}
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @lookback_days 7
  @min_deck_matches 8
  @min_baseline 30
  @max_p_value 0.10

  @impl true
  def tier, do: 2

  @impl true
  def detect(_opts) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@lookback_days, :day)
    baseline = baseline_wr()

    case baseline do
      nil ->
        nil

      {b_wr, b_n} ->
        cutoff
        |> per_deck_stats()
        |> Enum.filter(&(&1.n >= @min_deck_matches))
        |> annotate_with_significance(b_wr, b_n)
        |> pick_best_heater(b_wr, b_n)
    end
  end

  defp baseline_wr do
    {n, w} =
      Match
      |> where([m], not is_nil(m.won))
      |> select([m], {count(m.id), sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))})
      |> Repo.one()

    n = n || 0
    w = to_int(w)

    if n < @min_baseline, do: nil, else: {w / n, n}
  end

  defp per_deck_stats(cutoff) do
    Match
    |> where(
      [m],
      not is_nil(m.won) and not is_nil(m.mtga_deck_id) and m.started_at >= ^cutoff
    )
    |> group_by([m], [m.mtga_deck_id, m.deck_name])
    |> select([m], %{
      mtga_deck_id: m.mtga_deck_id,
      deck_name: m.deck_name,
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

  defp annotate_with_significance(rows, baseline_wr, baseline_n) do
    Enum.map(rows, fn row ->
      p_value = Significance.z_test_proportions(row.wr, row.n, baseline_wr, baseline_n)
      Map.put(row, :p_value, p_value)
    end)
  end

  defp pick_best_heater(rows, baseline_wr, baseline_n) do
    rows
    |> Enum.filter(&qualifying_heater?(&1, baseline_wr))
    |> case do
      [] ->
        nil

      heaters ->
        best = Enum.min_by(heaters, &p_value_for_sort/1)
        build_insight(best, baseline_wr, baseline_n)
    end
  end

  defp qualifying_heater?(%{wr: wr, p_value: p}, baseline_wr)
       when is_float(p) and p < @max_p_value do
    wr > baseline_wr
  end

  defp qualifying_heater?(_, _), do: false

  defp p_value_for_sort(%{p_value: p}) when is_float(p), do: p
  defp p_value_for_sort(_), do: 1.0

  defp build_insight(deck, baseline_wr, baseline_n) do
    %Insight{
      detector: "DeckHeater",
      surface: "home",
      tier: 2,
      title_template: "deck_heater.title",
      body_template: "deck_heater.body",
      stats: %{
        "primary" => %{"num" => format_pct(deck.wr), "lbl" => "7d WR"},
        "secondary" => %{"num" => format_pct(baseline_wr), "lbl" => "baseline"},
        "tertiary" => %{"num" => "n=#{deck.n}", "lbl" => "matches"}
      },
      measurements: %{
        "deck_name" => deck.deck_name,
        "mtga_deck_id" => deck.mtga_deck_id,
        "deck_wr" => deck.wr,
        "deck_n" => deck.n,
        "baseline_wr" => baseline_wr,
        "baseline_n" => baseline_n,
        "lookback_days" => @lookback_days,
        "p_value" => deck.p_value
      },
      sample_size: deck.n,
      confidence: deck.p_value,
      computed_at: DateTime.utc_now()
    }
  end

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
