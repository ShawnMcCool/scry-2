defmodule Scry2.Matches.UpdateFromEvent do
  @moduledoc """
  Pipeline stage 09 — project domain events into the `matches_*` read
  models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `matches_matches`, `matches_games`, `matches_deck_submissions` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.Events.append!/2` |

  ## Claimed domain events

    * `"match_created"` → seed match row with opponent, event, rank, format
    * `"match_completed"` → enrich with ended_at, won, num_games, duration
    * `"game_completed"` → upsert game row + accumulate game_results on match
    * `"deck_submitted"` → upsert deck submission + write deck_colors on match

  ## Idempotency

  All writes use upsert-by-mtga-id. Replaying the same domain event
  twice produces identical state (ADR-016).
  """
  # projection_tables listed in FK-safe delete order (children first)
  use Scry2.Events.Projector,
    claimed_slugs: ~w(match_created match_completed deck_submitted game_completed),
    projection_tables: [
      Scry2.Matches.DeckSubmission,
      Scry2.Matches.Game,
      Scry2.Matches.Match
    ]

  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.Match.{GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.Matches

  # ── Projection handlers ─────────────────────────────────────────────

  defp project(%MatchCreated{} = event) do
    attrs = %{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      event_name: event.event_name,
      opponent_screen_name: event.opponent_screen_name,
      started_at: event.occurred_at,
      player_rank: event.player_rank,
      format: event.format,
      format_type: event.format_type,
      deck_name: event.deck_name
    }

    match = Matches.upsert_match!(attrs)

    Log.info(
      :ingester,
      "projected MatchCreated mtga_match_id=#{match.mtga_match_id} opponent=#{inspect(event.opponent_screen_name)} deck=#{inspect(event.deck_name)}"
    )

    :ok
  end

  defp project(%MatchCompleted{} = event) do
    existing = Matches.get_by_mtga_id(event.mtga_match_id, event.player_id)

    duration =
      if existing && existing.started_at do
        DateTime.diff(event.occurred_at, existing.started_at, :second)
      end

    attrs = %{
      player_id: event.player_id,
      mtga_match_id: event.mtga_match_id,
      ended_at: event.occurred_at,
      won: event.won,
      num_games: event.num_games,
      duration_seconds: duration
    }

    match = Matches.upsert_match!(attrs)

    Log.info(
      :ingester,
      "projected MatchCompleted mtga_match_id=#{match.mtga_match_id} won=#{event.won} games=#{event.num_games}"
    )

    :ok
  end

  defp project(%GameCompleted{} = event) do
    match = Matches.get_by_mtga_id(event.mtga_match_id, event.player_id)

    if match do
      # Upsert the individual game row
      game_attrs = %{
        match_id: match.id,
        game_number: event.game_number,
        on_play: event.on_play,
        won: event.won,
        num_mulligans: event.num_mulligans,
        num_turns: event.num_turns,
        ended_at: event.occurred_at
      }

      Matches.upsert_game!(game_attrs)

      # Accumulate game_results on the match row
      prev_results = (match.game_results && match.game_results["results"]) || []
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

      Matches.upsert_match!(%{
        player_id: event.player_id,
        mtga_match_id: event.mtga_match_id,
        on_play: on_play,
        total_mulligans: total_mulligans,
        total_turns: total_turns,
        game_results: %{"results" => all_results}
      })

      Log.info(
        :ingester,
        "projected GameCompleted match=#{event.mtga_match_id} game=#{event.game_number}"
      )
    else
      Log.warning(
        :ingester,
        "GameCompleted for unknown match #{event.mtga_match_id} — skipping projection"
      )
    end

    :ok
  end

  defp project(%DeckSubmitted{} = event) do
    match =
      if event.mtga_match_id, do: Matches.get_by_mtga_id(event.mtga_match_id, event.player_id)

    # Upsert the deck submission row
    submission_attrs = %{
      mtga_deck_id: event.mtga_deck_id,
      match_id: match && match.id,
      main_deck: %{"cards" => event.main_deck},
      sideboard: %{"cards" => event.sideboard || []},
      submitted_at: event.occurred_at
    }

    Matches.upsert_deck_submission!(submission_attrs)

    # Write deck_colors on the match row
    if match do
      Matches.upsert_match!(%{
        player_id: event.player_id,
        mtga_match_id: event.mtga_match_id,
        deck_colors: event.deck_colors
      })
    end

    Log.info(
      :ingester,
      "projected DeckSubmitted mtga_deck_id=#{event.mtga_deck_id} colors=#{event.deck_colors}"
    )

    :ok
  end
end
