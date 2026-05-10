defmodule Scry2.Insights.Detectors.CraftingVelocity do
  @moduledoc """
  Surfaces wildcards crafted in the last 7 days, broken down by rarity.

  Tier 1 — pure SQL on `crafts.occurred_at_upper`, `crafts.rarity`,
  `crafts.quantity`. Returns `nil` if total crafts in the window is
  below the minimum activity threshold.
  """

  @behaviour Scry2.Insights.Detector

  import Ecto.Query

  alias Scry2.Crafts.Craft
  alias Scry2.Insights.Insight
  alias Scry2.Repo

  @lookback_days 7
  @min_total 3

  @impl true
  def tier, do: 1

  @impl true
  def detect(_opts) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@lookback_days, :day)

    rows =
      Craft
      |> where([c], c.occurred_at_upper >= ^cutoff)
      |> group_by([c], c.rarity)
      |> select([c], {c.rarity, sum(c.quantity)})
      |> Repo.all()
      |> Map.new(fn {r, n} -> {r, to_int(n)} end)

    total = rows |> Map.values() |> Enum.sum()

    if total < @min_total do
      nil
    else
      build_insight(rows, total)
    end
  end

  defp build_insight(rows, total) do
    mythics = Map.get(rows, "mythic", 0)
    rares = Map.get(rows, "rare", 0)
    uncommons = Map.get(rows, "uncommon", 0)

    %Insight{
      detector: "CraftingVelocity",
      surface: "home",
      tier: 1,
      title_template: "crafting_velocity.title",
      body_template: "crafting_velocity.body",
      stats: %{
        "primary" => %{"num" => "#{mythics}", "lbl" => "mythics"},
        "secondary" => %{"num" => "#{rares}", "lbl" => "rares"},
        "tertiary" => %{"num" => "#{total}", "lbl" => "total"}
      },
      measurements: %{
        "lookback_days" => @lookback_days,
        "mythics" => mythics,
        "rares" => rares,
        "uncommons" => uncommons,
        "total" => total,
        "by_rarity" => rows
      },
      sample_size: total,
      confidence: nil,
      computed_at: DateTime.utc_now()
    }
  end

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
end
