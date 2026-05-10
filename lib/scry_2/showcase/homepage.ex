defmodule Scry2.Showcase.Homepage do
  @moduledoc """
  Selects the four tiles for the Curator-style homepage exhibit.

  Two operating modes:

    * **Pattern mode** — at least one active insight exists. The Ranker
      scores all insights; the top three become γ coach tiles. The fourth
      slot is reserved for the latest-match α tile to keep the homepage
      grounded in recent activity.
    * **Activity mode** — no active insights. Falls back to the activity
      tile pool (currently just `latest_match`; more in later phases).

  Either way, the user always sees something useful. Coach voice fires
  only when a detector has earned the right to speak.
  """

  alias Scry2.Insights
  alias Scry2.Showcase.{Ranker, TileTypes}

  @max_tiles 4

  @doc "Returns up to four `%TileSpec{}`s for the homepage exhibit."
  @spec tiles(keyword()) :: [Scry2.Showcase.TileSpec.t()]
  def tiles(_opts \\ []) do
    case Insights.list_active(:home) do
      [] -> activity_mode_tiles()
      insights -> pattern_mode_tiles(insights)
    end
  end

  defp pattern_mode_tiles(insights) do
    now = DateTime.utc_now()

    coach_tiles =
      insights
      |> Enum.sort_by(&Ranker.score(&1, now), :desc)
      |> Enum.take(3)
      |> Enum.map(&TileTypes.CoachInsight.build/1)

    activity_tile = first_available_activity_tile()

    ([activity_tile] ++ coach_tiles)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_tiles)
  end

  defp activity_mode_tiles do
    activity_pool()
    |> Enum.take(@max_tiles)
  end

  # Pool order = priority. Pattern mode picks the first available; activity
  # mode takes the top @max_tiles. Add new builders here.
  defp activity_pool do
    [
      TileTypes.LatestMatch.build(),
      TileTypes.LatestDraft.build(),
      TileTypes.Climb.build(),
      TileTypes.RecentCrafts.build()
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp first_available_activity_tile do
    activity_pool() |> List.first()
  end
end
