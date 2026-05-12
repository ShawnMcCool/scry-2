defmodule Scry2.Insights.Detectors.ComebackArtist do
  @moduledoc """
  Detects whether the player's BO3 match win rate after losing game 1
  differs significantly from their match win rate after winning game 1.

  Tier 2 — joins `matches_matches` ⨝ `matches_games` (game 1 only) over
  Traditional (BO3) format. The two arms are mutually exclusive:

    * "comeback" — BO3 matches where the player lost game 1.
    * "up 1-0" — BO3 matches where the player won game 1.

  A two-proportion z-test compares match WR across the arms. The
  detector fires when both arms have at least 15 matches and the
  p-value is below 0.05.

  This is a resilience signal: a high comeback rate (relative to the
  up-1-0 rate) tells the player they tend to recover; a low one tells
  them they tend to spiral after a loss.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Insights.Insight
  alias Scry2.Insights.Significance
  alias Scry2.Matches.{Game, Match}
  alias Scry2.Repo

  @min_per_arm 15
  @p_threshold 0.05

  @impl true
  def tier, do: 2

  @impl true
  def detect(_opts) do
    rows =
      from(m in Match,
        join: g in Game,
        on: g.match_id == m.id and g.game_number == 1,
        where: m.format_type == "Traditional" and not is_nil(m.won) and not is_nil(g.won),
        select: {g.won, m.won}
      )
      |> Repo.all()

    {comeback_n, comeback_w, up_n, up_w} =
      Enum.reduce(rows, {0, 0, 0, 0}, fn
        {false, true}, {cn, cw, un, uw} -> {cn + 1, cw + 1, un, uw}
        {false, false}, {cn, cw, un, uw} -> {cn + 1, cw, un, uw}
        {true, true}, {cn, cw, un, uw} -> {cn, cw, un + 1, uw + 1}
        {true, false}, {cn, cw, un, uw} -> {cn, cw, un + 1, uw}
        _, acc -> acc
      end)

    cond do
      comeback_n < @min_per_arm or up_n < @min_per_arm ->
        nil

      true ->
        comeback_wr = comeback_w / comeback_n
        up_wr = up_w / up_n

        case Significance.z_test_proportions(comeback_wr, comeback_n, up_wr, up_n) do
          :undefined ->
            nil

          p when is_float(p) and p < @p_threshold ->
            build_insight(comeback_n, comeback_wr, up_n, up_wr, p)

          _ ->
            nil
        end
    end
  end

  defp build_insight(comeback_n, comeback_wr, up_n, up_wr, p) do
    direction = if comeback_wr >= up_wr, do: "comeback", else: "front_runner"

    %Insight{
      detector: "ComebackArtist",
      surface: "home",
      tier: 2,
      title_template: "comeback_artist.title",
      body_template: "comeback_artist.body",
      stats: %{
        "primary" => %{"num" => format_pct(comeback_wr), "lbl" => "after 0-1"},
        "secondary" => %{"num" => format_pct(up_wr), "lbl" => "after 1-0"},
        "tertiary" => %{"num" => "n=#{comeback_n}", "lbl" => "from 0-1"}
      },
      measurements: %{
        "direction" => direction,
        "comeback_n" => comeback_n,
        "comeback_wr" => comeback_wr,
        "up_1_0_n" => up_n,
        "up_1_0_wr" => up_wr,
        "gap" => comeback_wr - up_wr
      },
      sample_size: comeback_n + up_n,
      confidence: p,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
