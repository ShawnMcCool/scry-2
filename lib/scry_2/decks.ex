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

  alias Scry2.Decks.{Deck, DeckVersion, GameDraw, GameSubmission, MatchResult, MulliganHand}
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
  Returns completed match results for a deck, newest first, with pagination
  and optional format filter.

  Options:
    * `:limit` — max results per page (default 20)
    * `:offset` — pagination offset (default 0)
    * `:format` — `:bo1` or `:bo3` (default: all)

  Returns `{matches, total_count}`.
  """
  def list_matches_for_deck(mtga_deck_id, opts \\ []) when is_binary(mtga_deck_id) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    format = Keyword.get(opts, :format)

    base =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> apply_format_filter(format)

    total = Repo.aggregate(base, :count)

    matches =
      base
      |> order_by([mr], desc: mr.started_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {matches, total}
  end

  @doc """
  Returns the format (`:bo1` or `:bo3`) that was most recently played for a deck.
  Returns `:bo3` if no matches exist.
  """
  def most_recent_format(mtga_deck_id) when is_binary(mtga_deck_id) do
    latest =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> order_by([mr], desc: mr.started_at)
      |> limit(1)
      |> Repo.one()

    case latest do
      nil -> :bo3
      match -> if bo3?(match), do: :bo3, else: :bo1
    end
  end

  @doc """
  Returns `%{bo1: count, bo3: count}` for a deck — used to determine
  which format tabs should be enabled.
  """
  def match_counts_by_format(mtga_deck_id) when is_binary(mtga_deck_id) do
    base = where(MatchResult, [mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))

    bo3_count = base |> apply_format_filter(:bo3) |> Repo.aggregate(:count)
    bo1_count = base |> apply_format_filter(:bo1) |> Repo.aggregate(:count)

    %{bo1: bo1_count, bo3: bo3_count}
  end

  defp apply_format_filter(query, :bo3) do
    where(query, [mr], mr.format_type == "Traditional" or mr.num_games > 1)
  end

  defp apply_format_filter(query, :bo1) do
    where(
      query,
      [mr],
      (is_nil(mr.format_type) or mr.format_type != "Traditional") and
        (is_nil(mr.num_games) or mr.num_games <= 1)
    )
  end

  defp apply_format_filter(query, _), do: query

  # ── Analysis queries ──────────────────────────────────────────────────────

  @doc """
  Returns mulligan analytics for a single deck.

  Returns:
    * `:total_hands` — total mulligan offers
    * `:total_keeps` — hands kept
    * `:keep_rate` — percentage of hands kept
    * `:win_rate_on_7` — win rate when keeping a 7-card hand
    * `:by_hand_size` — keep rate per hand size (7, 6, 5...)
    * `:by_land_count` — win rate when keeping with N lands
  """
  def mulligan_analytics(mtga_deck_id) when is_binary(mtga_deck_id) do
    base = where(MulliganHand, [m], m.mtga_deck_id == ^mtga_deck_id)

    %{total_hands: total_hands, total_keeps: total_keeps} =
      base
      |> select([m], %{
        total_hands: count(),
        total_keeps: sum(fragment("CASE WHEN ? = 'kept' THEN 1 ELSE 0 END", m.decision))
      })
      |> Repo.one()
      |> then(fn row -> %{row | total_keeps: row.total_keeps || 0} end)

    by_hand_size =
      base
      |> where([m], not is_nil(m.decision))
      |> group_by([m], m.hand_size)
      |> select([m], %{
        hand_size: m.hand_size,
        total: count(),
        keeps: sum(fragment("CASE WHEN ? = 'kept' THEN 1 ELSE 0 END", m.decision))
      })
      |> order_by([m], desc: m.hand_size)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :keep_rate, win_rate(row.keeps, row.total)) end)

    by_land_count =
      base
      |> where([m], m.decision == "kept" and not is_nil(m.land_count) and not is_nil(m.match_won))
      |> group_by([m], m.land_count)
      |> select([m], %{
        land_count: m.land_count,
        total: count(),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.match_won))
      })
      |> order_by([m], asc: m.land_count)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :win_rate, win_rate(row.wins, row.total)) end)

    win_rate_on_7 =
      case Enum.find(by_hand_size, &(&1.hand_size == 7)) do
        nil -> nil
        row -> win_rate(row.keeps, row.total)
      end

    %{
      total_hands: total_hands,
      total_keeps: total_keeps,
      keep_rate: win_rate(total_keeps, total_hands),
      win_rate_on_7: win_rate_on_7,
      by_hand_size: by_hand_size,
      by_land_count: by_land_count
    }
  end

  @doc """
  Returns mulligan analytics across ALL decks (for the global stats page).
  Same shape as `mulligan_analytics/1` but unscoped.
  """
  def global_mulligan_analytics do
    base = MulliganHand

    %{total_hands: total_hands, total_keeps: total_keeps} =
      base
      |> select([m], %{
        total_hands: count(),
        total_keeps: sum(fragment("CASE WHEN ? = 'kept' THEN 1 ELSE 0 END", m.decision))
      })
      |> Repo.one()
      |> then(fn row -> %{row | total_keeps: row.total_keeps || 0} end)

    by_hand_size =
      base
      |> where([m], not is_nil(m.decision))
      |> group_by([m], m.hand_size)
      |> select([m], %{
        hand_size: m.hand_size,
        total: count(),
        keeps: sum(fragment("CASE WHEN ? = 'kept' THEN 1 ELSE 0 END", m.decision))
      })
      |> order_by([m], desc: m.hand_size)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :keep_rate, win_rate(row.keeps, row.total)) end)

    by_land_count =
      base
      |> where([m], m.decision == "kept" and not is_nil(m.land_count) and not is_nil(m.match_won))
      |> group_by([m], m.land_count)
      |> select([m], %{
        land_count: m.land_count,
        total: count(),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.match_won))
      })
      |> order_by([m], asc: m.land_count)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :win_rate, win_rate(row.wins, row.total)) end)

    %{
      total_hands: total_hands,
      total_keeps: total_keeps,
      by_hand_size: by_hand_size,
      by_land_count: by_land_count
    }
  end

  @doc """
  Returns a heatmap of hand_size x land_count for kept hands, with win rates.

  Each entry: `%{hand_size, land_count, count, wins, win_rate}`.
  """
  def mulligan_heatmap(mtga_deck_id) when is_binary(mtga_deck_id) do
    MulliganHand
    |> where(
      [m],
      m.mtga_deck_id == ^mtga_deck_id and
        m.decision == "kept" and
        not is_nil(m.land_count) and
        not is_nil(m.match_won)
    )
    |> group_by([m], [m.hand_size, m.land_count])
    |> select([m], %{
      hand_size: m.hand_size,
      land_count: m.land_count,
      count: count(),
      wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.match_won))
    })
    |> Repo.all()
    |> Enum.map(fn row -> Map.put(row, :win_rate, win_rate(row.wins, row.count)) end)
  end

  @doc """
  Returns per-card performance metrics for a deck, combining opening hand
  data from `decks_mulligan_hands` and mid-game draw data from `decks_cards_drawn`.

  Builds a unified per-card-per-match presence map to avoid double-counting
  cards that appear in both the opening hand and as a draw annotation.

  Each entry includes OH WR, GIH WR, GD WR, GND WR, and IWD.
  """
  def card_performance(mtga_deck_id) when is_binary(mtga_deck_id) do
    # Total completed matches and wins for this deck
    total_matches =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> select([mr], count())
      |> Repo.one()

    total_wins =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and mr.won == true)
      |> select([mr], count())
      |> Repo.one()

    # Build per-card, per-match presence: {arena_id, match_id} => %{in_opener, drawn, won}
    presence = build_card_match_presence(mtga_deck_id)

    deck = get_deck(mtga_deck_id)
    deck_cards = deck_card_counts(deck)

    # Resolve card names from the Cards table
    all_arena_ids = presence |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    card_names = Scry2.Cards.names_by_arena_ids(all_arena_ids)

    # Aggregate per card
    presence
    |> Enum.group_by(fn {{arena_id, _match_id}, _} -> arena_id end)
    |> Enum.map(fn {arena_id, entries} ->
      matches = Enum.map(entries, fn {_key, info} -> info end)

      oh_matches = Enum.filter(matches, & &1.in_opener)
      oh_games = length(oh_matches)
      oh_wins = Enum.count(oh_matches, & &1.won)

      # GD = drawn during game but NOT in opening hand
      gd_matches = Enum.filter(matches, &(&1.drawn && !&1.in_opener))
      gd_games = length(gd_matches)
      gd_wins = Enum.count(gd_matches, & &1.won)

      # GIH = union of opener and drawn (deduplicated by match)
      gih_games = length(matches)
      gih_wins = Enum.count(matches, & &1.won)

      gnd_games = max(total_matches - gih_games, 0)
      gnd_wins = max(total_wins - gih_wins, 0)

      oh_wr = win_rate(oh_wins, oh_games)
      gih_wr = win_rate(gih_wins, gih_games)
      gd_wr = win_rate(gd_wins, gd_games)
      gnd_wr = win_rate(gnd_wins, gnd_games)

      iwd =
        if gih_wr && gnd_wr do
          Float.round(gih_wr - gnd_wr, 1)
        end

      %{
        card_arena_id: arena_id,
        card_name: Map.get(card_names, arena_id),
        copies: Map.get(deck_cards, arena_id, 0),
        oh_wr: oh_wr,
        oh_games: oh_games,
        gih_wr: gih_wr,
        gih_games: gih_games,
        gd_wr: gd_wr,
        gd_games: gd_games,
        gnd_wr: gnd_wr,
        gnd_games: gnd_games,
        iwd: iwd,
        community: nil
      }
    end)
    |> Enum.sort_by(& &1.iwd, &((&1 || -999) >= (&2 || -999)))
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

  # ── Mulligan hand writes ──────────────────────────────────────────────────

  @doc """
  Upserts a mulligan hand by `(mtga_match_id, occurred_at)`. Idempotent per ADR-016.
  """
  def upsert_mulligan_hand!(attrs) do
    attrs = Map.new(attrs)

    %MulliganHand{}
    |> MulliganHand.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:mtga_match_id, :occurred_at]
    )
  end

  @doc """
  London mulligan rule: marks all existing hands for a match as `"mulliganed"`.
  Called just before inserting a new hand offer.
  """
  def stamp_mulligan_decision_mulliganed!(mtga_match_id) when is_binary(mtga_match_id) do
    from(m in MulliganHand, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [decision: "mulliganed"])
  end

  @doc "Backfills `mtga_deck_id` on mulligan hands for a match."
  def stamp_deck_id_on_mulligan_hands!(mtga_match_id, mtga_deck_id)
      when is_binary(mtga_match_id) and is_binary(mtga_deck_id) do
    from(m in MulliganHand,
      where: m.mtga_match_id == ^mtga_match_id and is_nil(m.mtga_deck_id)
    )
    |> Repo.update_all(set: [mtga_deck_id: mtga_deck_id])
  end

  @doc "Stamps `event_name` on all mulligan hands for a match."
  def stamp_mulligan_event_name!(mtga_match_id, event_name)
      when is_binary(mtga_match_id) and is_binary(event_name) do
    from(m in MulliganHand, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [event_name: event_name])
  end

  @doc "Stamps `match_won` on all mulligan hands for a match."
  def stamp_mulligan_match_won!(mtga_match_id, won)
      when is_binary(mtga_match_id) and is_boolean(won) do
    from(m in MulliganHand, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [match_won: won])
  end

  # ── Game draw writes ─────────────────────────────────────────────────────

  @doc """
  Upserts a game draw by `(mtga_match_id, game_number, card_arena_id, occurred_at)`.
  Idempotent per ADR-016.
  """
  def upsert_game_draw!(attrs) do
    attrs = Map.new(attrs)

    %GameDraw{}
    |> GameDraw.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:mtga_match_id, :game_number, :card_arena_id, :occurred_at]
    )
  end

  @doc "Backfills `mtga_deck_id` on game draws for a match."
  def stamp_deck_id_on_game_draws!(mtga_match_id, mtga_deck_id)
      when is_binary(mtga_match_id) and is_binary(mtga_deck_id) do
    from(d in GameDraw,
      where: d.mtga_match_id == ^mtga_match_id and is_nil(d.mtga_deck_id)
    )
    |> Repo.update_all(set: [mtga_deck_id: mtga_deck_id])
  end

  @doc "Stamps `match_won` on all game draws for a match."
  def stamp_game_draws_match_won!(mtga_match_id, won)
      when is_binary(mtga_match_id) and is_boolean(won) do
    from(d in GameDraw, where: d.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [match_won: won])
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

  # Builds a unified presence map: `{arena_id, match_id} => %{in_opener, drawn, won}`.
  # Deduplicates cards that appear in both the opening hand and as draw annotations
  # within the same match, preventing double-counting in GIH WR.
  defp build_card_match_presence(mtga_deck_id) do
    # Opening hand cards from kept hands
    oh_entries =
      MulliganHand
      |> where(
        [m],
        m.mtga_deck_id == ^mtga_deck_id and
          m.decision == "kept" and
          not is_nil(m.match_won)
      )
      |> Repo.all()
      |> Enum.flat_map(fn hand ->
        arena_ids = (hand.hand_arena_ids && hand.hand_arena_ids["cards"]) || []

        arena_ids
        |> Enum.uniq()
        |> Enum.map(fn arena_id ->
          {{arena_id, hand.mtga_match_id}, %{in_opener: true, drawn: false, won: hand.match_won}}
        end)
      end)

    # Mid-game draw entries
    draw_entries =
      GameDraw
      |> where([d], d.mtga_deck_id == ^mtga_deck_id and not is_nil(d.match_won))
      |> select([d], {d.card_arena_id, d.mtga_match_id, d.match_won})
      |> Repo.all()
      |> Enum.uniq_by(fn {arena_id, match_id, _} -> {arena_id, match_id} end)
      |> Enum.map(fn {arena_id, match_id, won} ->
        {{arena_id, match_id}, %{in_opener: false, drawn: true, won: won}}
      end)

    # Merge: if a card appears in both opener and draws for the same match,
    # combine the flags (in_opener: true, drawn: true)
    (oh_entries ++ draw_entries)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, infos} ->
      merged =
        Enum.reduce(infos, %{in_opener: false, drawn: false, won: false}, fn info, acc ->
          %{
            in_opener: acc.in_opener || info.in_opener,
            drawn: acc.drawn || info.drawn,
            won: acc.won || info.won
          }
        end)

      {key, merged}
    end)
  end

  # Extracts `%{arena_id => count}` from a deck's current main deck composition.
  defp deck_card_counts(nil), do: %{}

  defp deck_card_counts(%Deck{} = deck) do
    cards = (deck.current_main_deck && deck.current_main_deck["cards"]) || []

    Map.new(cards, fn card ->
      {card["arena_id"] || card[:arena_id], card["count"] || card[:count] || 1}
    end)
  end

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
