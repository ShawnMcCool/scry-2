defmodule Scry2.MatchListing.UpdateFromEvent do
  @moduledoc """
  Projects domain events into the `matches_match_listing` read model
  for the matches list page.

  Pure writer — events arrive fully enriched from the ingestion pipeline
  (ADR-030). No card metadata lookups, no format inference. Just map
  event fields to projection columns and write.

  ## Claimed domain events

  * `"match_created"` → seed row with opponent info, event name, rank, format
  * `"match_completed"` → enrich with ended_at, won, num_games, duration
  * `"game_completed"` → accumulate game_results, derive on_play / totals
  * `"deck_submitted"` → write deck_colors (pre-enriched on the event)
  """

  use Scry2.Events.Projector,
    claimed_slugs: ~w(match_created match_completed game_completed deck_submitted),
    projection_tables: [Scry2.MatchListing.MatchListing]

  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.Match.{GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.MatchListing

  # ── Projection handlers ─────────────────────────────────────────────

  defp project(%MatchCreated{player_id: nil}), do: :ok

  defp project(%MatchCreated{} = event) do
    MatchListing.upsert!(%{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      event_name: event.event_name,
      opponent_screen_name: event.opponent_screen_name,
      started_at: event.occurred_at,
      player_rank: event.player_rank,
      format: event.format,
      format_type: event.format_type
    })

    :ok
  end

  defp project(%MatchCompleted{player_id: nil}), do: :ok

  defp project(%MatchCompleted{} = event) do
    existing = MatchListing.get_by_mtga_id(event.mtga_match_id, event.player_id)

    duration =
      if existing && existing.started_at do
        DateTime.diff(event.occurred_at, existing.started_at, :second)
      end

    MatchListing.upsert!(%{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      ended_at: event.occurred_at,
      won: event.won,
      num_games: event.num_games,
      duration_seconds: duration
    })

    :ok
  end

  defp project(%GameCompleted{player_id: nil}), do: :ok

  defp project(%GameCompleted{} = event) do
    existing = MatchListing.get_by_mtga_id(event.mtga_match_id, event.player_id)

    prev_results = (existing && existing.game_results && existing.game_results["results"]) || []
    other_results = Enum.reject(prev_results, &(&1["game"] == event.game_number))

    new_result = %{
      "game" => event.game_number,
      "won" => event.won,
      "on_play" => event.on_play,
      "turns" => event.num_turns,
      "mulligans" => event.num_mulligans
    }

    all_results = Enum.sort_by(other_results ++ [new_result], & &1["game"])

    total_mulligans = all_results |> Enum.map(&(&1["mulligans"] || 0)) |> Enum.sum()
    total_turns = all_results |> Enum.map(&(&1["turns"] || 0)) |> Enum.sum()

    game_1 = Enum.find(all_results, &(&1["game"] == 1))
    on_play = game_1 && game_1["on_play"]

    MatchListing.upsert!(%{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      on_play: on_play,
      total_mulligans: total_mulligans,
      total_turns: total_turns,
      game_results: %{"results" => all_results}
    })

    :ok
  end

  defp project(%DeckSubmitted{player_id: nil}), do: :ok

  defp project(%DeckSubmitted{} = event) do
    MatchListing.upsert!(%{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      deck_colors: event.deck_colors
    })

    :ok
  end

  defp project(_event), do: :ok
end
