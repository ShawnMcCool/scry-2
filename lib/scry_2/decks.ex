defmodule Scry2.Decks do
  @moduledoc """
  Context module for constructed deck tracking.

  Owns tables: `decks_decks`, `decks_deck_versions`, `decks_match_results`,
  `decks_game_submissions`.

  PubSub role:
    * subscribes to `"domain:events"` (via `Scry2.Decks.DeckProjection`)
    * broadcasts `"decks:updates"` after any mutation

  All upserts are idempotent by MTGA ids (ADR-016). Stats queries stay
  entirely within `decks_*` tables — no cross-context joins (ADR-031).
  """

  import Ecto.Query

  alias Scry2.Decks.{Deck, DeckVersion, GameSubmission, MatchResult}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Reads ─────────────────────────────────────────────────────────────────

  @doc """
  Returns decks with aggregated BO1 and BO3 stats.

  Options:
    * `:only_played` — when `true` (default), only returns decks with at least
      one completed match. When `false`, returns all decks including unplayed ones.

  Played decks sort by `last_played_at` descending; unplayed decks follow,
  sorted by `last_updated_at` descending.

  Each entry is a map:
    * `:deck` — `%Deck{}`
    * `:bo1` — `%{total, wins, losses, win_rate}`
    * `:bo3` — `%{total, wins, losses, win_rate}`
  """
  def list_decks_with_stats(player_id \\ nil, opts \\ []) do
    only_played = Keyword.get(opts, :only_played, true)

    decks =
      Deck
      |> maybe_filter_player(player_id)
      |> order_by([d], desc_nulls_last: d.last_played_at, desc: d.last_updated_at)
      |> Repo.all()

    deck_ids = Enum.map(decks, & &1.mtga_deck_id)

    stats_by_deck_id = aggregate_stats_for_decks(deck_ids)

    decks
    |> maybe_filter_played(stats_by_deck_id, only_played)
    |> Enum.map(fn deck ->
      row = Map.get(stats_by_deck_id, deck.mtga_deck_id, %{})
      %{deck: deck, bo1: build_stats(row, :bo1), bo3: build_stats(row, :bo3)}
    end)
  end

  @doc "Returns the deck with the given MTGA deck id, or nil."
  def get_deck(mtga_deck_id) when is_binary(mtga_deck_id) do
    Repo.get_by(Deck, mtga_deck_id: mtga_deck_id)
  end

  @doc "Returns the number of deck versions for a deck."
  def count_versions(mtga_deck_id) when is_binary(mtga_deck_id) do
    DeckVersion
    |> where([dv], dv.mtga_deck_id == ^mtga_deck_id)
    |> select([dv], count(dv.id))
    |> Repo.one()
  end

  @doc """
  Returns aggregated performance stats for a single deck.

  Returns a map with:
    * `:bo1` — `%{total, wins, losses, win_rate, on_play_win_rate, on_draw_win_rate}`
    * `:bo3` — same plus `%{game1_win_rate, games_2_3_win_rate}`
    * `:cumulative_win_rate` — `%{bo1: [...], bo3: [...]}` where each entry is
      `%{timestamp, win_rate, wins, total}` for a running win rate line chart
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
      cumulative_win_rate: %{
        bo1: cumulative_win_rate(bo1_results),
        bo3: cumulative_win_rate(bo3_results)
      }
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
  Returns all deck versions for a deck, newest first.
  Each version includes pre-computed diffs and match stats.
  """
  def get_deck_versions(mtga_deck_id) when is_binary(mtga_deck_id) do
    DeckVersion
    |> where([dv], dv.mtga_deck_id == ^mtga_deck_id)
    |> order_by([dv], desc: dv.version_number)
    |> Repo.all()
  end

  @doc """
  Returns the next version number for a deck (max + 1, or 1 if no versions).
  """
  def next_version_number(mtga_deck_id) when is_binary(mtga_deck_id) do
    DeckVersion
    |> where([dv], dv.mtga_deck_id == ^mtga_deck_id)
    |> select([dv], max(dv.version_number))
    |> Repo.one()
    |> then(fn
      nil -> 1
      max -> max + 1
    end)
  end

  @doc """
  Returns the version that was active for a deck at a given timestamp,
  i.e. the latest version with `occurred_at <= timestamp`. Returns nil
  if no version exists before that time.
  """
  def get_active_version_at(mtga_deck_id, %DateTime{} = timestamp) do
    DeckVersion
    |> where([dv], dv.mtga_deck_id == ^mtga_deck_id and dv.occurred_at <= ^timestamp)
    |> order_by([dv], desc: dv.occurred_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns match results grouped by deck version number.
  Matches are bucketed by the version active at match start time.
  Returns `%{version_number => [%MatchResult{}]}`.
  """
  def get_matches_by_version(mtga_deck_id) when is_binary(mtga_deck_id) do
    versions =
      DeckVersion
      |> where([dv], dv.mtga_deck_id == ^mtga_deck_id)
      |> order_by([dv], asc: dv.version_number)
      |> select([dv], {dv.version_number, dv.occurred_at})
      |> Repo.all()

    matches =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> order_by([mr], desc: mr.started_at)
      |> Repo.all()

    bucket_matches_by_version(versions, matches)
  end

  @doc """
  Returns all completed match results for a deck, newest first.
  """
  def list_matches_for_deck(mtga_deck_id) when is_binary(mtga_deck_id) do
    MatchResult
    |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
    |> order_by([mr], desc: mr.started_at)
    |> Repo.all()
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
  Upserts a deck version by `(mtga_deck_id, version_number)`. Idempotent for replay.
  """
  def upsert_deck_version!(attrs) do
    attrs = Map.new(attrs)
    mtga_deck_id = attrs[:mtga_deck_id]
    version_number = attrs[:version_number]

    case Repo.get_by(DeckVersion, mtga_deck_id: mtga_deck_id, version_number: version_number) do
      nil -> %DeckVersion{}
      existing -> existing
    end
    |> DeckVersion.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  @doc """
  Increments win/loss stats on the version that was active when a match started.
  No-op if no version exists for the deck at that time.
  """
  def increment_version_stats!(mtga_deck_id, %DateTime{} = started_at, match_result) do
    case get_active_version_at(mtga_deck_id, started_at) do
      nil ->
        :ok

      version ->
        won = match_result.won
        on_play = match_result.on_play

        updates =
          if won do
            [match_wins: version.match_wins + 1] ++
              if(on_play,
                do: [on_play_wins: version.on_play_wins + 1],
                else: [on_draw_wins: version.on_draw_wins + 1]
              )
          else
            [match_losses: version.match_losses + 1] ++
              if(on_play,
                do: [on_play_losses: version.on_play_losses + 1],
                else: [on_draw_losses: version.on_draw_losses + 1]
              )
          end

        version
        |> DeckVersion.changeset(Map.new(updates))
        |> Repo.update!()
    end
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

  defp maybe_filter_played(decks, _stats_by_deck_id, false), do: decks

  defp maybe_filter_played(decks, stats_by_deck_id, true) do
    Enum.filter(decks, fn deck ->
      row = Map.get(stats_by_deck_id, deck.mtga_deck_id, %{bo1_total: 0, bo3_total: 0})
      row.bo1_total + row.bo3_total > 0
    end)
  end

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

  defp cumulative_win_rate(results) do
    results
    |> Enum.filter(& &1.started_at)
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.map_reduce({0, 0}, fn match_result, {wins, total} ->
      new_wins = if match_result.won, do: wins + 1, else: wins
      new_total = total + 1

      point = %{
        timestamp: DateTime.to_iso8601(match_result.started_at),
        win_rate: win_rate(new_wins, new_total),
        wins: new_wins,
        total: new_total
      }

      {point, {new_wins, new_total}}
    end)
    |> elem(0)
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

  # Assigns each match to the version that was active at match start time.
  # Versions are sorted ascending by version_number. A match belongs to version N
  # if started_at >= version_N.occurred_at and (started_at < version_N+1.occurred_at or N is last).
  defp bucket_matches_by_version([], _matches), do: %{}

  defp bucket_matches_by_version(versions, matches) do
    # Build time boundaries: [{version_number, start, end}]
    boundaries =
      versions
      |> Enum.with_index()
      |> Enum.map(fn {{version_number, occurred_at}, index} ->
        next_occurred_at =
          case Enum.at(versions, index + 1) do
            {_next_num, next_at} -> next_at
            nil -> nil
          end

        {version_number, occurred_at, next_occurred_at}
      end)

    Enum.reduce(matches, %{}, fn match, acc ->
      case find_version_for_match(boundaries, match.started_at) do
        nil -> acc
        version_number -> Map.update(acc, version_number, [match], &[match | &1])
      end
    end)
  end

  defp find_version_for_match(_boundaries, nil), do: nil

  defp find_version_for_match(boundaries, started_at) do
    Enum.find_value(boundaries, fn {version_number, occurred_at, next_occurred_at} ->
      after_start = DateTime.compare(started_at, occurred_at) in [:gt, :eq]

      before_end =
        is_nil(next_occurred_at) or DateTime.compare(started_at, next_occurred_at) == :lt

      if after_start and before_end, do: version_number
    end)
  end

  defp broadcast_update(mtga_deck_id) do
    Topics.broadcast(Topics.decks_updates(), {:deck_updated, mtga_deck_id})
  end
end
