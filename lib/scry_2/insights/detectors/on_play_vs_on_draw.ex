defmodule Scry2.Insights.Detectors.OnPlayVsOnDraw do
  @moduledoc """
  Detects the gap between win rate on the play and on the draw.

  Tier 1 — pure SQL on `matches_matches.on_play` + `matches_matches.won`.
  Fires when total recorded matches with both fields populated is at least
  the minimum sample threshold. No significance test (Tier 1).
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @min_n 30

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    {play_n, play_wins, draw_n, draw_wins} = split_counts()
    total_n = play_n + draw_n

    if total_n < @min_n do
      nil
    else
      build_insight(play_n, play_wins, draw_n, draw_wins, total_n)
    end
  end

  defp split_counts do
    rows =
      Match
      |> where([m], not is_nil(m.on_play) and not is_nil(m.won))
      |> group_by([m], m.on_play)
      |> select([m], {
        m.on_play,
        count(m.id),
        sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))
      })
      |> Repo.all()

    Enum.reduce(rows, {0, 0, 0, 0}, fn
      {true, n, w}, {_, _, d_n, d_w} -> {n || 0, to_int(w), d_n, d_w}
      {false, n, w}, {p_n, p_w, _, _} -> {p_n, p_w, n || 0, to_int(w)}
    end)
  end

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)

  defp build_insight(play_n, play_wins, draw_n, draw_wins, total_n) do
    play_wr = if play_n == 0, do: 0.0, else: play_wins / play_n
    draw_wr = if draw_n == 0, do: 0.0, else: draw_wins / draw_n
    gap = play_wr - draw_wr

    %Insight{
      detector: "OnPlayVsOnDraw",
      surface: "home",
      tier: 1,
      title_template: "on_play_vs_on_draw.title",
      body_template: "on_play_vs_on_draw.body",
      stats: %{
        "primary" => %{"num" => format_pct(play_wr), "lbl" => "play"},
        "secondary" => %{"num" => format_pct(draw_wr), "lbl" => "draw"},
        "tertiary" => %{"num" => "n=#{total_n}", "lbl" => "matches"}
      },
      measurements: %{
        "on_play_wr" => play_wr,
        "on_draw_wr" => draw_wr,
        "on_play_n" => play_n,
        "on_draw_n" => draw_n,
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
