defmodule Scry2.Ranks.RankProjection do
  @moduledoc """
  Projects `rank_advanced` domain events into the `ranks_snapshots`
  read model.

  Each `RankAdvanced` event becomes one row in the progression history.
  """
  use Scry2.Events.Projector,
    claimed_slugs: ~w(rank_advanced),
    projection_tables: [Scry2.Ranks.Snapshot]

  alias Scry2.Events.Progression.RankAdvanced
  alias Scry2.Ranks

  defp project(%RankAdvanced{} = event) do
    Ranks.insert_snapshot!(%{
      player_id: event.player_id,
      constructed_class: event.constructed_class,
      constructed_level: event.constructed_level,
      constructed_step: event.constructed_step,
      constructed_matches_won: event.constructed_matches_won,
      constructed_matches_lost: event.constructed_matches_lost,
      limited_class: event.limited_class,
      limited_level: event.limited_level,
      limited_step: event.limited_step,
      limited_matches_won: event.limited_matches_won,
      limited_matches_lost: event.limited_matches_lost,
      season_ordinal: event.season_ordinal,
      occurred_at: event.occurred_at
    })

    Log.info(:ingester, "projected RankAdvanced at #{event.occurred_at}")
    :ok
  end

  defp project(_event), do: :ok
end
