defmodule Scry2.Decks.DeckProjection do
  @moduledoc """
  Pipeline stage 09 — project domain events into the `decks_*` read models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `decks_decks`, `decks_deck_versions`, `decks_match_results`, `decks_game_submissions`, `decks_mulligan_hands`, `decks_cards_drawn` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.Events.append!/2` |

  ## Claimed domain events

    * `"deck_updated"` → upsert `decks_decks` with current name, composition, format;
      create version row in `decks_deck_versions` with pre-computed diffs
    * `"deck_submitted"` → upsert `decks_game_submissions`; update `first_seen_at` /
      `last_played_at` on `decks_decks`; seed `decks_match_results` row
    * `"match_created"` → enrich `decks_match_results` with format_type, event_name,
      player_rank, started_at (if a deck submission exists for this match)
    * `"match_completed"` → enrich `decks_match_results` with won, num_games, completed_at;
      increment version stats on the active `decks_deck_versions` row
    * `"game_completed"` → accumulate game_results on `decks_match_results` for BO3
      game 1 vs games 2/3 analysis; captures on_play from game 1
    * `"mulligan_offered"` → upsert `decks_mulligan_hands`; London mulligan rule stamps
      prior hands as mulliganed; resolves deck_id from match_results
    * `"card_drawn"` → upsert `decks_cards_drawn`; resolves deck_id from match_results

  ## Idempotency

  All writes use upsert-by-mtga-id. Replaying the same domain event
  twice produces identical state (ADR-016).
  """

  # projection_tables listed in FK-safe delete order (children first)
  use Scry2.Events.Projector,
    claimed_slugs:
      ~w(deck_updated deck_submitted match_created match_completed game_completed mulligan_offered card_drawn),
    projection_tables: [
      Scry2.Decks.GameDraw,
      Scry2.Decks.MulliganHand,
      Scry2.Decks.GameSubmission,
      Scry2.Decks.MatchResult,
      Scry2.Decks.DeckVersion,
      Scry2.Decks.Deck
    ]

  import Ecto.Query

  alias Scry2.Decks
  alias Scry2.Decks.MatchResult
  alias Scry2.Events.Deck.{DeckSubmitted, DeckUpdated}
  alias Scry2.Events.EnrichEvents
  alias Scry2.Events.EventName
  alias Scry2.Events.Gameplay.{CardDrawn, MulliganOffered}
  alias Scry2.Events.Match.{GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.Repo

  # ── Projection handlers ─────────────────────────────────────────────

  defp project(%DeckUpdated{} = event) do
    if event.deck_id do
      attrs = %{
        mtga_deck_id: event.deck_id,
        current_name: event.deck_name,
        current_main_deck: %{"cards" => event.main_deck || []},
        current_sideboard: %{"cards" => event.sideboard || []},
        format: event.format,
        last_updated_at: event.occurred_at
      }

      Decks.upsert_deck!(attrs)

      version_number = Decks.next_version_number(event.deck_id)

      Decks.upsert_deck_version!(%{
        mtga_deck_id: event.deck_id,
        version_number: version_number,
        deck_name: event.deck_name,
        action_type: event.action_type,
        main_deck: %{"cards" => event.main_deck || []},
        sideboard: %{"cards" => event.sideboard || []},
        main_deck_added: %{"cards" => event.main_deck_added || []},
        main_deck_removed: %{"cards" => event.main_deck_removed || []},
        sideboard_added: %{"cards" => event.sideboard_added || []},
        sideboard_removed: %{"cards" => event.sideboard_removed || []},
        occurred_at: event.occurred_at
      })

      Log.info(
        :ingester,
        "projected DeckUpdated deck_id=#{event.deck_id} name=#{inspect(event.deck_name)} version=#{version_number}"
      )
    end

    :ok
  end

  defp project(%DeckSubmitted{} = event) do
    if event.mtga_deck_id && event.mtga_match_id do
      # Resolve a stable deck identity. For constructed decks, composition
      # matching links to the DeckUpdated-sourced row. For draft/limited
      # matches, all games in the same draft run share one deck row keyed
      # by event_name. Falls back to the per-match synthetic ID.
      match_created_attrs = find_match_created_attrs(event.mtga_match_id)

      mtga_deck_id =
        resolve_deck_id_by_composition(event.main_deck) ||
          resolve_deck_id_for_draft(match_created_attrs) ||
          event.mtga_deck_id

      # Upsert game submission row for sideboard diff analysis
      Decks.upsert_game_submission!(%{
        mtga_deck_id: mtga_deck_id,
        mtga_match_id: event.mtga_match_id,
        game_number: event.game_number || 1,
        main_deck: %{"cards" => event.main_deck || []},
        sideboard: %{"cards" => event.sideboard || []},
        submitted_at: event.occurred_at
      })

      # Update first_seen_at / last_played_at / deck_colors on the deck row.
      # For draft decks, also seed the display name and format.
      existing = Decks.get_deck(mtga_deck_id)

      deck_attrs =
        if existing do
          updates = %{
            mtga_deck_id: mtga_deck_id,
            last_played_at: event.occurred_at,
            deck_colors: event.deck_colors || existing.deck_colors || ""
          }

          if is_nil(existing.first_seen_at) or
               DateTime.compare(event.occurred_at, existing.first_seen_at) == :lt do
            Map.put(updates, :first_seen_at, event.occurred_at)
          else
            updates
          end
        else
          base = %{
            mtga_deck_id: mtga_deck_id,
            first_seen_at: event.occurred_at,
            last_played_at: event.occurred_at,
            deck_colors: event.deck_colors || ""
          }

          maybe_add_draft_name(base, match_created_attrs)
        end

      deck = Decks.upsert_deck!(deck_attrs)

      # Backfill nil format from the match's event_name. DeckUpdated sometimes
      # carries event-type strings ("DirectGame") that normalize_deck_format/1
      # filters to nil. The match's event_name reliably identifies the format.
      if is_nil(deck.format) do
        event_name = match_created_attrs[:event_name]
        inferred = EnrichEvents.infer_deck_format(event_name)

        if inferred do
          Decks.upsert_deck!(%{mtga_deck_id: mtga_deck_id, format: inferred})
        end
      end

      # Seed match result row. MatchCreated fires before DeckSubmitted in the
      # MTGA event stream, so retroactively apply any already-persisted
      # MatchCreated data to avoid leaving format_type nil.
      Decks.upsert_match_result!(
        Map.merge(match_created_attrs, %{
          mtga_deck_id: mtga_deck_id,
          mtga_match_id: event.mtga_match_id
        })
      )

      # Backfill deck_id on mulligan hands and game draws that arrived
      # before this DeckSubmitted (MulliganOffered fires before deck context)
      Decks.stamp_deck_id_on_mulligan_hands!(event.mtga_match_id, mtga_deck_id)
      Decks.stamp_deck_id_on_game_draws!(event.mtga_match_id, mtga_deck_id)

      Log.info(
        :ingester,
        "projected DeckSubmitted deck_id=#{mtga_deck_id} match=#{event.mtga_match_id} game=#{event.game_number}"
      )
    end

    :ok
  end

  defp project(%MatchCreated{} = event) do
    # Enrich any match result rows for this match with context data.
    # May be a no-op if no deck submission exists for this match yet
    # (ordering is non-deterministic; DeckSubmitted often arrives first).
    enrich_match_results(event.mtga_match_id, %{
      format_type: event.format_type,
      event_name: event.event_name,
      player_rank: event.player_rank,
      opponent_screen_name: event.opponent_screen_name,
      opponent_rank: compose_rank(event.opponent_rank_class, event.opponent_rank_tier),
      started_at: event.occurred_at
    })

    # Stamp event_name on mulligan hands for this match
    if event.event_name do
      Decks.stamp_mulligan_event_name!(event.mtga_match_id, event.event_name)
    end

    :ok
  end

  defp project(%MatchCompleted{} = event) do
    enrich_match_results(event.mtga_match_id, %{
      won: event.won,
      num_games: event.num_games,
      completed_at: event.occurred_at
    })

    # MatchCompleted.game_results carries authoritative per-game win/loss
    # from the matchmaking layer. The GRE's GameCompleted events are
    # unreliable for conceded games. Correct the game_results map here.
    if event.game_results do
      correct_game_results(event.mtga_match_id, event.game_results)
    end

    # Update version stats for each deck that played this match
    update_version_stats_for_match(event.mtga_match_id)

    # Stamp match outcome on mulligan hands and game draws
    if is_boolean(event.won) do
      Decks.stamp_mulligan_match_won!(event.mtga_match_id, event.won)
      Decks.stamp_game_draws_match_won!(event.mtga_match_id, event.won)
    end

    Log.info(
      :ingester,
      "projected MatchCompleted onto decks match=#{event.mtga_match_id} won=#{event.won}"
    )

    :ok
  end

  defp project(%GameCompleted{} = event) do
    # Accumulate per-game results on decks_match_results for BO3 game 1 vs 2/3 analysis.
    # Look up each deck result for this match (there may be one per deck used in the match).
    match_results =
      MatchResult
      |> where([mr], mr.mtga_match_id == ^event.mtga_match_id)
      |> Repo.all()

    Enum.each(match_results, fn existing ->
      if existing do
        prev_results = (existing.game_results && existing.game_results["results"]) || []
        other_results = Enum.reject(prev_results, &(&1["game"] == event.game_number))

        new_result = %{
          "game" => event.game_number,
          "won" => event.won,
          "on_play" => event.on_play,
          "num_mulligans" => event.num_mulligans || 0
        }

        all_results = Enum.sort_by(other_results ++ [new_result], & &1["game"])

        # on_play for the match is determined by game 1
        game1 = Enum.find(all_results, &(&1["game"] == 1))
        on_play = game1 && game1["on_play"]

        Decks.upsert_match_result!(%{
          mtga_deck_id: existing.mtga_deck_id,
          mtga_match_id: event.mtga_match_id,
          game_results: %{"results" => all_results},
          on_play: on_play
        })
      end
    end)

    :ok
  end

  defp project(%MulliganOffered{} = event) do
    if event.mtga_match_id do
      # Resolve deck_id from an existing match_results row (may be nil
      # if DeckSubmitted hasn't fired yet — backfilled later)
      mtga_deck_id = resolve_deck_id_for_match(event.mtga_match_id)

      # London mulligan rule: mark all prior hands for this match as mulliganed
      Decks.stamp_mulligan_decision_mulliganed!(event.mtga_match_id)

      Decks.upsert_mulligan_hand!(%{
        mtga_deck_id: mtga_deck_id,
        mtga_match_id: event.mtga_match_id,
        seat_id: event.seat_id,
        hand_size: event.hand_size,
        hand_arena_ids: %{"cards" => event.hand_arena_ids || []},
        land_count: event.land_count,
        nonland_count: event.nonland_count,
        total_cmc: event.total_cmc,
        cmc_distribution: event.cmc_distribution,
        color_distribution: event.color_distribution,
        card_names: event.card_names,
        decision: "kept",
        occurred_at: event.occurred_at
      })
    end

    :ok
  end

  defp project(%CardDrawn{} = event) do
    if event.mtga_match_id && event.card_arena_id do
      mtga_deck_id = resolve_deck_id_for_match(event.mtga_match_id)

      Decks.upsert_game_draw!(%{
        mtga_deck_id: mtga_deck_id,
        mtga_match_id: event.mtga_match_id,
        game_number: event.game_number,
        card_arena_id: event.card_arena_id,
        card_name: event.card_name,
        turn_number: event.turn_number,
        occurred_at: event.occurred_at
      })
    end

    :ok
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # Looks up the mtga_deck_id for a match from the existing match_results row.
  # Returns nil if no match result exists yet (MulliganOffered can fire before
  # DeckSubmitted). The caller inserts with nil and DeckSubmitted backfills later.
  defp resolve_deck_id_for_match(mtga_match_id) do
    MatchResult
    |> where([mr], mr.mtga_match_id == ^mtga_match_id)
    |> select([mr], mr.mtga_deck_id)
    |> limit(1)
    |> Repo.one()
  end

  # For Limited-format matches (drafts, sealed), returns a stable deck ID
  # derived from the event_name so all matches from the same draft run
  # consolidate under one deck row. Returns nil for non-Limited matches.
  defp resolve_deck_id_for_draft(%{event_name: event_name}) when is_binary(event_name) do
    case EnrichEvents.infer_format(event_name) do
      {_format, "Limited"} -> "draft:#{event_name}"
      _ -> nil
    end
  end

  defp resolve_deck_id_for_draft(_), do: nil

  # Seeds current_name and format on a new draft deck row from the
  # MatchCreated event_name (e.g. "Quick Draft — TMT").
  defp maybe_add_draft_name(attrs, %{event_name: event_name}) when is_binary(event_name) do
    parsed = EventName.parse(event_name)

    case parsed.format_type do
      "Limited" ->
        display_name =
          if parsed.set_code, do: "#{parsed.format} — #{parsed.set_code}", else: parsed.format

        Map.merge(attrs, %{current_name: display_name, format: parsed.format})

      _ ->
        attrs
    end
  end

  defp maybe_add_draft_name(attrs, _), do: attrs

  # Finds the stable MTGA deck UUID for a submitted composition by comparing
  # the main deck card list against all known decks in decks_decks.
  # DeckUpdated (which carries the real UUID) always fires before DeckSubmitted
  # for the same deck, so the row exists by the time this is called.
  # Only the main deck is compared — sideboard changes between BO3 games.
  defp resolve_deck_id_by_composition([]), do: nil

  defp resolve_deck_id_by_composition(main_deck) do
    submitted_sorted =
      main_deck
      |> Enum.map(fn card ->
        {card["arena_id"] || card[:arena_id], card["count"] || card[:count]}
      end)
      |> Enum.sort()

    Scry2.Repo.all(Scry2.Decks.Deck)
    |> Enum.find_value(fn deck ->
      known_sorted =
        ((deck.current_main_deck && deck.current_main_deck["cards"]) || [])
        |> Enum.map(fn card ->
          {card["arena_id"] || card[:arena_id], card["count"] || card[:count]}
        end)
        |> Enum.sort()

      if known_sorted == submitted_sorted, do: deck.mtga_deck_id
    end)
  end

  # Queries the Events log for an already-persisted MatchCreated event so that
  # DeckSubmitted can retroactively populate format_type/event_name/player_rank
  # when MatchCreated fired before the deck row existed.
  defp find_match_created_attrs(mtga_match_id) do
    case Scry2.Events.list_events(
           event_types: ["match_created"],
           match_id: mtga_match_id,
           limit: 1
         ) do
      {[event], _} ->
        %{
          format_type: event.format_type,
          event_name: event.event_name,
          player_rank: event.player_rank,
          opponent_screen_name: event.opponent_screen_name,
          opponent_rank: compose_rank(event.opponent_rank_class, event.opponent_rank_tier),
          started_at: event.occurred_at
        }

      _ ->
        %{}
    end
  end

  # Corrects per-game `won` values in game_results using MatchCompleted's
  # authoritative data. The GRE's GameCompleted reports the last game state,
  # which is wrong for conceded games (opponent concedes while ahead).
  defp correct_game_results(mtga_match_id, authoritative_games) do
    won_by_game =
      Map.new(authoritative_games, fn g ->
        game_num = g["game_number"] || g[:game_number]
        won = if is_nil(g["won"]), do: g[:won], else: g["won"]
        {game_num, won}
      end)

    MatchResult
    |> where([mr], mr.mtga_match_id == ^mtga_match_id)
    |> Repo.all()
    |> Enum.each(fn match_result ->
      prev = (match_result.game_results && match_result.game_results["results"]) || []

      if prev != [] do
        corrected =
          Enum.map(prev, fn game ->
            case Map.get(won_by_game, game["game"]) do
              nil -> game
              won -> Map.put(game, "won", won)
            end
          end)

        Decks.upsert_match_result!(%{
          mtga_deck_id: match_result.mtga_deck_id,
          mtga_match_id: mtga_match_id,
          game_results: %{"results" => corrected}
        })
      end
    end)
  end

  defp enrich_match_results(mtga_match_id, attrs) do
    deck_ids =
      MatchResult
      |> where([mr], mr.mtga_match_id == ^mtga_match_id)
      |> select([mr], mr.mtga_deck_id)
      |> Repo.all()

    Enum.each(deck_ids, fn mtga_deck_id ->
      Decks.upsert_match_result!(
        Map.merge(attrs, %{mtga_deck_id: mtga_deck_id, mtga_match_id: mtga_match_id})
      )
    end)
  end

  defp update_version_stats_for_match(mtga_match_id) do
    MatchResult
    |> where([mr], mr.mtga_match_id == ^mtga_match_id and not is_nil(mr.won))
    |> Repo.all()
    |> Enum.each(fn match_result ->
      if match_result.started_at do
        Decks.increment_version_stats!(
          match_result.mtga_deck_id,
          match_result.started_at,
          match_result
        )
      end
    end)
  end

  defp compose_rank(nil, _tier), do: nil
  defp compose_rank(class, nil), do: class
  defp compose_rank(class, tier), do: "#{class} #{tier}"
end
