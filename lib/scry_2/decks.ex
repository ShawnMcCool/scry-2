defmodule Scry2.Decks do
  @moduledoc """
  Context module for constructed deck tracking.

  Owns tables: `decks_decks`, `decks_match_results`, `decks_game_submissions`.

  PubSub role:
    * subscribes to `"domain:events"` (via `Scry2.Decks.DeckProjection`)
    * broadcasts `"decks:updates"` after any mutation

  All upserts are idempotent by MTGA ids (ADR-016). Stats queries stay
  entirely within `decks_*` tables — no cross-context joins (ADR-031).
  """

  import Ecto.Query

  alias Scry2.Decks.{Deck, GameSubmission, MatchResult}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Reads ─────────────────────────────────────────────────────────────────

  @doc """
  Returns all decks that have at least one completed match, with aggregated
  BO1 and BO3 stats. Sorted by last_played_at descending.

  Each entry is a map:
    * `:deck` — `%Deck{}`
    * `:bo1` — `%{total, wins, losses, win_rate}`
    * `:bo3` — `%{total, wins, losses, win_rate}`
  """
  def list_decks_with_stats(player_id \\ nil) do
    decks =
      Deck
      |> maybe_filter_player(player_id)
      |> order_by([d], desc: d.last_played_at)
      |> Repo.all()

    deck_ids = Enum.map(decks, & &1.mtga_deck_id)

    stats_by_deck_id = aggregate_stats_for_decks(deck_ids)

    decks
    |> Enum.filter(fn deck ->
      row = Map.get(stats_by_deck_id, deck.mtga_deck_id, %{bo1_total: 0, bo3_total: 0})
      row.bo1_total + row.bo3_total > 0
    end)
    |> Enum.map(fn deck ->
      row = Map.get(stats_by_deck_id, deck.mtga_deck_id, %{})
      %{deck: deck, bo1: build_stats(row, :bo1), bo3: build_stats(row, :bo3)}
    end)
  end

  @doc "Returns the deck with the given MTGA deck id, or nil."
  def get_deck(mtga_deck_id) when is_binary(mtga_deck_id) do
    Repo.get_by(Deck, mtga_deck_id: mtga_deck_id)
  end

  @doc """
  Returns aggregated performance stats for a single deck.

  Returns a map with:
    * `:bo1` — `%{total, wins, losses, win_rate, on_play_win_rate, on_draw_win_rate}`
    * `:bo3` — same plus `%{game1_win_rate, games_2_3_win_rate}`
    * `:win_rate_by_week` — `[%{week, bo1_win_rate, bo3_win_rate}]` for chart
  """
  def get_deck_performance(mtga_deck_id) when is_binary(mtga_deck_id) do
    results =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> Repo.all()

    bo1_results = Enum.reject(results, &bo3?/1)
    bo3_results = Enum.filter(results, &bo3?/1)

    %{
      bo1: compute_detailed_stats(bo1_results, :bo1),
      bo3: compute_detailed_stats(bo3_results, :bo3),
      win_rate_by_week: win_rate_by_week(results)
    }
  end

  @doc """
  Returns per-match sideboard diff data for a BO3 deck.

  Each entry is a map:
    * `:mtga_match_id`
    * `:started_at`
    * `:won`
    * `:game1_sideboard` — cards in sideboard for game 1
    * `:later_sideboards` — cards in sideboard for games 2+
    * `:changes` — `%{added: [...], removed: [...]}` from game 1 to game 2/3
  """
  def get_deck_sideboard_diff(mtga_deck_id) when is_binary(mtga_deck_id) do
    submissions =
      GameSubmission
      |> where([gs], gs.mtga_deck_id == ^mtga_deck_id)
      |> order_by([gs], asc: gs.mtga_match_id, asc: gs.game_number)
      |> Repo.all()

    results =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> select([mr], {mr.mtga_match_id, mr.won, mr.started_at})
      |> Repo.all()
      |> Map.new(fn {mtga_match_id, won, started_at} ->
        {mtga_match_id, %{won: won, started_at: started_at}}
      end)

    submissions
    |> Enum.group_by(& &1.mtga_match_id)
    |> Enum.filter(fn {_, games} -> length(games) > 1 end)
    |> Enum.map(fn {mtga_match_id, games} ->
      game1 = Enum.find(games, &(&1.game_number == 1))
      later_games = Enum.filter(games, &(&1.game_number > 1))
      result = Map.get(results, mtga_match_id, %{})

      game1_sideboard = parse_cards(game1 && game1.sideboard)
      later_sideboard = later_games |> List.first() |> then(&parse_cards(&1 && &1.sideboard))
      changes = sideboard_diff(game1_sideboard, later_sideboard)

      %{
        mtga_match_id: mtga_match_id,
        started_at: result[:started_at],
        won: result[:won],
        game1_sideboard: game1_sideboard,
        later_sideboards: later_sideboard,
        changes: changes
      }
    end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Returns `DeckUpdated` domain events for the given deck, newest first.
  Used to render the evolution timeline.
  """
  def get_deck_evolution(mtga_deck_id) when is_binary(mtga_deck_id) do
    alias Scry2.Events
    alias Scry2.Events.Deck.DeckUpdated

    # Fetch recent deck_updated events globally and filter to this deck.
    # Limit of 500 is sufficient for a single-player app — a user is unlikely
    # to have more deck_updated events than this across all decks.
    {events, _total} = Events.list_events(event_types: ["deck_updated"], limit: 500)

    events
    |> Enum.filter(&(is_struct(&1, DeckUpdated) and &1.deck_id == mtga_deck_id))
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
  end

  # ── Writes ────────────────────────────────────────────────────────────────

  @doc """
  Upserts a deck by `mtga_deck_id`. Idempotent per ADR-016.
  """
  def upsert_deck!(attrs) do
    attrs = Map.new(attrs)
    mtga_deck_id = attrs[:mtga_deck_id] || attrs["mtga_deck_id"]

    deck =
      case Repo.get_by(Deck, mtga_deck_id: mtga_deck_id) do
        nil -> %Deck{}
        existing -> existing
      end
      |> Deck.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(deck.mtga_deck_id)
    deck
  end

  @doc """
  Upserts a match result by `(mtga_deck_id, mtga_match_id)`. Idempotent per ADR-016.
  """
  def upsert_match_result!(attrs) do
    attrs = Map.new(attrs)
    mtga_deck_id = attrs[:mtga_deck_id] || attrs["mtga_deck_id"]
    mtga_match_id = attrs[:mtga_match_id] || attrs["mtga_match_id"]

    result =
      case Repo.get_by(MatchResult, mtga_deck_id: mtga_deck_id, mtga_match_id: mtga_match_id) do
        nil -> %MatchResult{}
        existing -> existing
      end
      |> MatchResult.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(result.mtga_deck_id)
    result
  end

  @doc """
  Upserts a game submission by `(mtga_deck_id, mtga_match_id, game_number)`. Idempotent per ADR-016.
  """
  def upsert_game_submission!(attrs) do
    attrs = Map.new(attrs)
    mtga_deck_id = attrs[:mtga_deck_id] || attrs["mtga_deck_id"]
    mtga_match_id = attrs[:mtga_match_id] || attrs["mtga_match_id"]
    game_number = attrs[:game_number] || attrs["game_number"]

    submission =
      case Repo.get_by(GameSubmission,
             mtga_deck_id: mtga_deck_id,
             mtga_match_id: mtga_match_id,
             game_number: game_number
           ) do
        nil -> %GameSubmission{}
        existing -> existing
      end
      |> GameSubmission.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(submission.mtga_deck_id)
    submission
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # decks_decks has no player_id — the context is single-player by design.
  defp maybe_filter_player(query, _player_id), do: query

  defp aggregate_stats_for_decks([]), do: %{}

  defp aggregate_stats_for_decks(deck_ids) do
    MatchResult
    |> where([mr], mr.mtga_deck_id in ^deck_ids and not is_nil(mr.won))
    |> group_by([mr], mr.mtga_deck_id)
    |> select([mr], %{
      mtga_deck_id: mr.mtga_deck_id,
      bo3_total:
        sum(
          fragment(
            "CASE WHEN ? = 'Traditional' OR ? > 1 THEN 1 ELSE 0 END",
            mr.format_type,
            mr.num_games
          )
        ),
      bo3_wins:
        sum(
          fragment(
            "CASE WHEN (? = 'Traditional' OR ? > 1) AND ? = 1 THEN 1 ELSE 0 END",
            mr.format_type,
            mr.num_games,
            mr.won
          )
        ),
      bo1_total:
        sum(
          fragment(
            "CASE WHEN COALESCE(?, '') != 'Traditional' AND COALESCE(?, 1) <= 1 THEN 1 ELSE 0 END",
            mr.format_type,
            mr.num_games
          )
        ),
      bo1_wins:
        sum(
          fragment(
            "CASE WHEN COALESCE(?, '') != 'Traditional' AND COALESCE(?, 1) <= 1 AND ? = 1 THEN 1 ELSE 0 END",
            mr.format_type,
            mr.num_games,
            mr.won
          )
        )
    })
    |> Repo.all()
    |> Map.new(&{&1.mtga_deck_id, &1})
  end

  defp build_stats(row, :bo1) do
    total = row[:bo1_total] || 0
    wins = row[:bo1_wins] || 0
    %{total: total, wins: wins, losses: total - wins, win_rate: win_rate(wins, total)}
  end

  defp build_stats(row, :bo3) do
    total = row[:bo3_total] || 0
    wins = row[:bo3_wins] || 0
    %{total: total, wins: wins, losses: total - wins, win_rate: win_rate(wins, total)}
  end

  defp compute_detailed_stats(results, format_type) do
    total = length(results)
    wins = Enum.count(results, & &1.won)
    on_play = Enum.filter(results, & &1.on_play)
    on_draw = Enum.reject(results, & &1.on_play)

    base = %{
      total: total,
      wins: wins,
      losses: total - wins,
      win_rate: win_rate(wins, total),
      on_play_total: length(on_play),
      on_play_wins: Enum.count(on_play, & &1.won),
      on_play_win_rate: win_rate(Enum.count(on_play, & &1.won), length(on_play)),
      on_draw_total: length(on_draw),
      on_draw_wins: Enum.count(on_draw, & &1.won),
      on_draw_win_rate: win_rate(Enum.count(on_draw, & &1.won), length(on_draw))
    }

    if format_type == :bo3 do
      {game1_wins, game1_total, later_wins, later_total} = bo3_game_split(results)

      Map.merge(base, %{
        game1_total: game1_total,
        game1_wins: game1_wins,
        game1_win_rate: win_rate(game1_wins, game1_total),
        games_2_3_total: later_total,
        games_2_3_wins: later_wins,
        games_2_3_win_rate: win_rate(later_wins, later_total)
      })
    else
      base
    end
  end

  defp bo3_game_split(results) do
    Enum.reduce(results, {0, 0, 0, 0}, fn mr, {g1w, g1t, lw, lt} ->
      game_results = (mr.game_results && mr.game_results["results"]) || []
      game1 = Enum.find(game_results, &(&1["game"] == 1))
      later = Enum.filter(game_results, &(&1["game"] > 1))

      g1w_new = if game1 && game1["won"], do: g1w + 1, else: g1w
      g1t_new = if game1, do: g1t + 1, else: g1t
      lw_new = lw + Enum.count(later, & &1["won"])
      lt_new = lt + length(later)

      {g1w_new, g1t_new, lw_new, lt_new}
    end)
  end

  defp win_rate_by_week(results) do
    results
    |> Enum.filter(& &1.started_at)
    |> Enum.group_by(fn mr ->
      date = DateTime.to_date(mr.started_at)
      Date.beginning_of_week(date)
    end)
    |> Enum.map(fn {week, group} ->
      bo1 = Enum.reject(group, &bo3?/1)
      bo3 = Enum.filter(group, &bo3?/1)
      bo1_wins = Enum.count(bo1, & &1.won)
      bo3_wins = Enum.count(bo3, & &1.won)

      %{
        week: Date.to_iso8601(week),
        bo1_total: length(bo1),
        bo1_wins: bo1_wins,
        bo1_win_rate: win_rate(bo1_wins, length(bo1)),
        bo3_total: length(bo3),
        bo3_wins: bo3_wins,
        bo3_win_rate: win_rate(bo3_wins, length(bo3))
      }
    end)
    |> Enum.sort_by(& &1.week)
  end

  # A match is BO3 if format_type is "Traditional" (ranked queues) OR
  # num_games > 1 (DirectGame BO3 challenges, where format_type is nil).
  defp bo3?(%MatchResult{format_type: "Traditional"}), do: true

  defp bo3?(%MatchResult{num_games: num_games}) when is_integer(num_games) and num_games > 1,
    do: true

  defp bo3?(_), do: false

  defp win_rate(_, 0), do: nil
  defp win_rate(wins, total), do: Float.round(wins / total * 100, 1)

  defp parse_cards(nil), do: []
  defp parse_cards(%{"cards" => cards}), do: cards
  defp parse_cards(cards) when is_list(cards), do: cards

  defp sideboard_diff(game1_cards, later_cards) do
    game1_map =
      Map.new(game1_cards, fn card ->
        {card["arena_id"] || card[:arena_id], card["count"] || card[:count] || 1}
      end)

    later_map =
      Map.new(later_cards, fn card ->
        {card["arena_id"] || card[:arena_id], card["count"] || card[:count] || 1}
      end)

    all_ids = MapSet.union(MapSet.new(Map.keys(game1_map)), MapSet.new(Map.keys(later_map)))

    changes =
      Enum.reduce(all_ids, %{added: [], removed: []}, fn arena_id, acc ->
        g1_count = Map.get(game1_map, arena_id, 0)
        later_count = Map.get(later_map, arena_id, 0)

        cond do
          later_count > g1_count ->
            Map.update!(acc, :added, &[%{arena_id: arena_id, count: later_count - g1_count} | &1])

          g1_count > later_count ->
            Map.update!(
              acc,
              :removed,
              &[%{arena_id: arena_id, count: g1_count - later_count} | &1]
            )

          true ->
            acc
        end
      end)

    changes
  end

  defp broadcast_update(mtga_deck_id) do
    Topics.broadcast(Topics.decks_updates(), {:deck_updated, mtga_deck_id})
  end
end
