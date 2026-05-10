defmodule Scry2.Showcase.TileTypes.RecentCrafts do
  @moduledoc """
  α tease tile summarising wildcards crafted in the last 7 days.

  Title is the highest-rarity-first count (e.g. "3 mythics, 5 rares").
  Subtitle is empty. Meta carries the lookback window. No fabricated
  narrative.

  Activity-mode tile — fires whenever there's at least one craft in
  the lookback window. Returns `nil` otherwise.
  """

  import Ecto.Query

  alias Scry2.Crafts.Craft
  alias Scry2.Repo
  alias Scry2.Showcase.TileSpec

  @lookback_days 7
  @rarity_order [
    {"mythic", "mythic", "mythics"},
    {"rare", "rare", "rares"},
    {"uncommon", "uncommon", "uncommons"},
    {"common", "common", "commons"}
  ]

  @spec build(keyword()) :: TileSpec.t() | nil
  def build(_opts \\ []) do
    case totals() do
      totals when map_size(totals) == 0 -> nil
      totals -> render(totals)
    end
  end

  defp totals do
    cutoff = DateTime.utc_now() |> DateTime.add(-@lookback_days, :day)

    Craft
    |> where([c], c.occurred_at_upper >= ^cutoff)
    |> group_by([c], c.rarity)
    |> select([c], {c.rarity, sum(c.quantity)})
    |> Repo.all()
    |> Map.new(fn {r, n} -> {r, to_int(n)} end)
    |> Map.reject(fn {_, n} -> n == 0 end)
  end

  defp render(totals) do
    parts =
      @rarity_order
      |> Enum.flat_map(fn {key, singular, plural} ->
        case Map.get(totals, key, 0) do
          0 -> []
          1 -> ["1 #{singular}"]
          n -> ["#{n} #{plural}"]
        end
      end)

    title =
      case parts do
        [] -> "0 crafts"
        [head] -> head
        [a, b | _] -> "#{a}, #{b}"
      end

    %TileSpec{
      kind: :recent_crafts,
      kind_label: "this week's crafting",
      composition: :activity,
      title: title,
      body: nil,
      art: nil,
      meta: ["last #{@lookback_days} days"],
      target: {:navigate, "/economy"}
    }
  end

  defp to_int(nil), do: 0
  defp to_int(int) when is_integer(int), do: int
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
end
