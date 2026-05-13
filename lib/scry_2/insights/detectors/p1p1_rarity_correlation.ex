defmodule Scry2.Insights.Detectors.P1P1RarityCorrelation do
  @moduledoc """
  Detects whether the rarity of your first pack first pick correlates
  with draft outcome.

  Tier 1 — pure SQL joining `drafts_drafts` ⨝ `drafts_picks` (pack 1
  pick 1) ⨝ `cards_cards` for rarity. Splits drafts into "P1P1 rare or
  mythic" vs "P1P1 common or uncommon", computes draft win rate per
  bucket. Returns an insight when both buckets have meaningful samples
  and the gap is large enough.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Cards.Card
  alias Scry2.Drafts.{Draft, Pick}
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  @min_per_bucket 5
  @min_gap 0.08

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    rows =
      from(d in Draft,
        join: p in Pick,
        on: p.draft_id == d.id and p.pack_number == 1 and p.pick_number == 1,
        join: c in Card,
        on: c.arena_id == p.picked_arena_id,
        where: not is_nil(d.completed_at) and not is_nil(d.wins) and not is_nil(d.losses),
        select: {c.rarity, d.wins, d.losses}
      )
      |> Repo.all()

    aggregate_and_build(rows)
  end

  defp aggregate_and_build(rows) do
    {rare_n, rare_w, rare_g, other_n, other_w, other_g} =
      Enum.reduce(rows, {0, 0, 0, 0, 0, 0}, fn {rarity, wins, losses}, acc ->
        wins = wins || 0
        losses = losses || 0
        games = wins + losses
        bucket(rarity, wins, games, acc)
      end)

    cond do
      rare_n < @min_per_bucket ->
        nil

      other_n < @min_per_bucket ->
        nil

      rare_g == 0 or other_g == 0 ->
        nil

      true ->
        rare_wr = rare_w / rare_g
        other_wr = other_w / other_g
        gap = rare_wr - other_wr

        if abs(gap) < @min_gap do
          nil
        else
          build_insight(rare_n, rare_wr, other_n, other_wr, gap)
        end
    end
  end

  defp bucket(r, w, g, {rn, rw, rg, on, ow, og}) when r in ["rare", "mythic"] do
    {rn + 1, rw + w, rg + g, on, ow, og}
  end

  defp bucket(_r, w, g, {rn, rw, rg, on, ow, og}) do
    {rn, rw, rg, on + 1, ow + w, og + g}
  end

  defp build_insight(rare_n, rare_wr, other_n, other_wr, gap) do
    total = rare_n + other_n

    %Insight{
      detector: "P1P1RarityCorrelation",
      surface: "home",
      tier: 1,
      title_template: "p1p1_rarity.title",
      body_template: "p1p1_rarity.body",
      stats: %{
        "primary" => %{"num" => format_pct(rare_wr), "lbl" => "rare P1P1"},
        "secondary" => %{"num" => format_pct(other_wr), "lbl" => "other P1P1"},
        "tertiary" => %{"num" => "#{total}", "lbl" => "drafts"}
      },
      measurements: %{
        "rare_wr" => rare_wr,
        "rare_n" => rare_n,
        "other_wr" => other_wr,
        "other_n" => other_n,
        "total_n" => total,
        "gap" => gap
      },
      sample_size: total,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
