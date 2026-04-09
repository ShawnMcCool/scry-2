defmodule Scry2.Mulligans.MulliganProjection do
  @moduledoc """
  Projects domain events into the `mulligans_mulligan_listing` read model.

  Pure writer — events arrive fully enriched from the ingestion pipeline
  (ADR-030). No external lookups. Just map event fields to projection
  columns and write.

  ## Claimed domain events

    * `"mulligan_offered"` → mark prior hands for this match as mulliganed,
      then upsert the new hand as `"kept"` (tentative)
    * `"match_created"` → stamp `event_name` on existing rows for that match
    * `"match_completed"` → stamp `match_won` on all rows for that match
  """

  use Scry2.Events.Projector,
    claimed_slugs: ~w(mulligan_offered match_created match_completed),
    projection_tables: [Scry2.Mulligans.MulliganListing]

  alias Scry2.Events.Gameplay.MulliganOffered
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.Mulligans

  defp project(%MulliganOffered{} = event) do
    Mulligans.stamp_decision_mulliganed!(event.mtga_match_id)

    Mulligans.upsert_hand!(%{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      seat_id: event.seat_id,
      hand_size: event.hand_size,
      hand_arena_ids: %{"cards" => event.hand_arena_ids || []},
      occurred_at: event.occurred_at,
      land_count: event.land_count,
      nonland_count: event.nonland_count,
      total_cmc: event.total_cmc,
      cmc_distribution: event.cmc_distribution,
      color_distribution: event.color_distribution,
      card_names: event.card_names,
      decision: "kept"
    })

    :ok
  end

  defp project(%MatchCreated{} = event) do
    if event.mtga_match_id && event.event_name do
      Mulligans.stamp_event_name!(event.mtga_match_id, event.event_name)
    end

    :ok
  end

  defp project(%MatchCompleted{} = event) do
    if event.mtga_match_id do
      Mulligans.stamp_match_won!(event.mtga_match_id, event.won)
    end

    :ok
  end

  defp project(_event), do: :ok
end
