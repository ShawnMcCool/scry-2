defmodule Scry2.Decks.DeckProjection do
  @moduledoc """
  Pipeline stage 09 — project domain events into the `decks_*` read models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `decks_decks`, `decks_deck_versions`, `decks_match_results`, `decks_game_submissions` |
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

  ## Idempotency

  All writes use upsert-by-mtga-id. Replaying the same domain event
  twice produces identical state (ADR-016).
  """

  # projection_tables listed in FK-safe delete order (children first)
  use Scry2.Events.Projector,
    claimed_slugs: ~w(deck_updated deck_submitted match_created match_completed game_completed),
    projection_tables: [
      Scry2.Decks.GameSubmission,
      Scry2.Decks.MatchResult,
      Scry2.Decks.DeckVersion,
      Scry2.Decks.Deck
    ]

  alias Scry2.Decks
  alias Scry2.Events.Deck.{DeckSubmitted, DeckUpdated}
  alias Scry2.Events.EnrichEvents
  alias Scry2.Events.Match.{GameCompleted, MatchCompleted, MatchCreated}

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

      Decks.upsert_deck!(deck_attrs)

      # Seed match result row. MatchCreated fires before DeckSubmitted in the
      # MTGA event stream, so retroactively apply any already-persisted
      # MatchCreated data to avoid leaving format_type nil.
      Decks.upsert_match_result!(
        Map.merge(match_created_attrs, %{
          mtga_deck_id: mtga_deck_id,
          mtga_match_id: event.mtga_match_id
        })
      )

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
      started_at: event.occurred_at
    })

    :ok
  end

  defp project(%MatchCompleted{} = event) do
    enrich_match_results(event.mtga_match_id, %{
      won: event.won,
      num_games: event.num_games,
      completed_at: event.occurred_at
    })

    # Update version stats for each deck that played this match
    update_version_stats_for_match(event.mtga_match_id)

    Log.info(
      :ingester,
      "projected MatchCompleted onto decks match=#{event.mtga_match_id} won=#{event.won}"
    )

    :ok
  end

  defp project(%GameCompleted{} = event) do
    # Accumulate per-game results on decks_match_results for BO3 game 1 vs 2/3 analysis.
    # Look up each deck result for this match (there may be one per deck used in the match).
    import Ecto.Query
    alias Scry2.Decks.MatchResult
    alias Scry2.Repo

    deck_ids =
      MatchResult
      |> where([mr], mr.mtga_match_id == ^event.mtga_match_id)
      |> select([mr], mr.mtga_deck_id)
      |> Repo.all()

    Enum.each(deck_ids, fn mtga_deck_id ->
      existing =
        Repo.get_by(MatchResult, mtga_deck_id: mtga_deck_id, mtga_match_id: event.mtga_match_id)

      if existing do
        prev_results = (existing.game_results && existing.game_results["results"]) || []
        other_results = Enum.reject(prev_results, &(&1["game"] == event.game_number))

        new_result = %{
          "game" => event.game_number,
          "won" => event.won,
          "on_play" => event.on_play
        }

        all_results = Enum.sort_by(other_results ++ [new_result], & &1["game"])

        # on_play for the match is determined by game 1
        game1 = Enum.find(all_results, &(&1["game"] == 1))
        on_play = game1 && game1["on_play"]

        Decks.upsert_match_result!(%{
          mtga_deck_id: mtga_deck_id,
          mtga_match_id: event.mtga_match_id,
          game_results: %{"results" => all_results},
          on_play: on_play
        })
      end
    end)

    :ok
  end

  # ── Private helpers ─────────────────────────────────────────────────

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
    case EnrichEvents.infer_format(event_name) do
      {format, "Limited"} ->
        set_code = extract_set_code(event_name)
        display_name = if set_code, do: "#{format} — #{set_code}", else: format

        Map.merge(attrs, %{current_name: display_name, format: format})

      _ ->
        attrs
    end
  end

  defp maybe_add_draft_name(attrs, _), do: attrs

  # Extracts a 3-letter set code from event_name strings like
  # "QuickDraft_TMT_20260407" or "MWM_TMT_BotDraft_20260407".
  # Skips the leading queue-type segment (e.g. "MWM") by dropping the first
  # part when multiple 3-letter candidates exist.
  defp extract_set_code(event_name) do
    candidates =
      event_name
      |> String.split("_")
      |> Enum.filter(fn part ->
        String.length(part) == 3 and part =~ ~r/^[A-Z]+$/
      end)

    case candidates do
      [_prefix, set_code | _] -> set_code
      [set_code] -> set_code
      _ -> nil
    end
  end

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
          started_at: event.occurred_at
        }

      _ ->
        %{}
    end
  end

  defp enrich_match_results(mtga_match_id, attrs) do
    import Ecto.Query
    alias Scry2.Decks.MatchResult
    alias Scry2.Repo

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
    import Ecto.Query
    alias Scry2.Decks.MatchResult
    alias Scry2.Repo

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
end
