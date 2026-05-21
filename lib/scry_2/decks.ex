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

  alias Scry2.Analytics.RollingWindow

  alias Scry2.Decks.{
    Deck,
    DeckSummary,
    DeckVersion,
    FormatStats,
    GameDraw,
    GameSubmission,
    MatchResult,
    MulliganHand
  }

  alias Scry2.LiveState.{RankClass, Snapshot}
  alias Scry2.Ranks.Format, as: RankFormat
  alias Scry2.Repo
  alias Scry2.Topics

  require Scry2.Log, as: Log

  # ── Reads ─────────────────────────────────────────────────────────────────

  @doc """
  Returns decks with aggregated BO1 and BO3 stats.

  Options:
    * `:only_played` — when `true` (default), only returns decks with at least
      one completed match. When `false`, returns all decks including unplayed ones.
    * `:status` — `:active` (only `archived=false`), `:archived` (only
      `archived=true`), or `:all` (default). Used by the deck-collection
      view to separate active decks from those deleted in MTGA.
    * `:starred_only` — when `true`, returns only decks with `starred=true`.
      Default `false`.

  Played decks sort by `last_played_at` descending; unplayed decks follow,
  sorted by `last_updated_at` descending.

  Each entry is a `%Scry2.Decks.DeckSummary{}` struct with `:deck`, `:bo1`,
  and `:bo3` (the latter two are `%Scry2.Decks.FormatStats{}`).
  """
  @spec list_decks_with_stats(integer() | nil, keyword()) :: [DeckSummary.t()]
  def list_decks_with_stats(player_id \\ nil, opts \\ []) do
    only_played = Keyword.get(opts, :only_played, true)
    status = Keyword.get(opts, :status, :all)
    starred_only = Keyword.get(opts, :starred_only, false)

    Deck
    |> maybe_filter_by_player(player_id)
    |> maybe_filter_played_in_sql(only_played)
    |> filter_by_status(status)
    |> maybe_filter_starred(starred_only)
    |> order_by([d], desc_nulls_last: d.last_played_at, desc: d.last_updated_at)
    |> Repo.all()
    |> Enum.map(fn deck ->
      %DeckSummary{
        deck: deck,
        bo1: format_stats(deck.bo1_wins, deck.bo1_losses),
        bo3: format_stats(deck.bo3_wins, deck.bo3_losses)
      }
    end)
  end

  defp format_stats(wins, losses) do
    %FormatStats{
      total: wins + losses,
      wins: wins,
      losses: losses,
      win_rate: win_rate(wins, wins + losses)
    }
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

  Options:
    * `:days` — rolling-window size for the win-rate chart series. When
      `nil` (default), the series is cumulative (every prior match counts).

  Returns a map with:
    * `:bo1` — `%{total, wins, losses, win_rate, on_play_win_rate, on_draw_win_rate}`
    * `:bo3` — same plus `%{game1_win_rate, games_2_3_win_rate}`
    * `:cumulative_win_rate` — `%{bo1: [...], bo3: [...]}` where each entry is
      `%{timestamp, win_rate, wins, total}` for the win-rate line chart.
      The key name is preserved for backward compatibility — when `:days`
      is set, the values are rolling-window averages.
  """
  def get_deck_performance(mtga_deck_id, opts \\ []) when is_binary(mtga_deck_id) do
    days = Keyword.get(opts, :days)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      bo1: aggregate_deck_format_stats(mtga_deck_id, :bo1),
      bo3: aggregate_deck_bo3_stats(mtga_deck_id),
      cumulative_win_rate: %{
        bo1: deck_rolling_win_rate(mtga_deck_id, :bo1, days, now),
        bo3: deck_rolling_win_rate(mtga_deck_id, :bo3, days, now)
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
  def latest_format(mtga_deck_id) when is_binary(mtga_deck_id) do
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
    %{bo1: bo1_count, bo3: bo3_count} =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> select([mr], %{
        bo3:
          sum(
            fragment(
              "CASE WHEN ? = 'Traditional' OR ? > 1 THEN 1 ELSE 0 END",
              mr.format_type,
              mr.num_games
            )
          ),
        bo1:
          sum(
            fragment(
              "CASE WHEN COALESCE(?, '') != 'Traditional' AND COALESCE(?, 1) <= 1 THEN 1 ELSE 0 END",
              mr.format_type,
              mr.num_games
            )
          )
      })
      |> Repo.one()

    %{bo1: bo1_count || 0, bo3: bo3_count || 0}
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
    {total_matches, total_wins} = deck_match_totals(mtga_deck_id)
    raw_aggregates = card_match_aggregates(mtga_deck_id)
    deck = get_deck(mtga_deck_id)
    deck_cards = deck_card_counts(deck)

    aggregates = exclude_token_rows(raw_aggregates)
    card_names = Scry2.Cards.names_by_arena_ids(Enum.map(aggregates, & &1.arena_id))

    aggregates
    |> Enum.map(&build_card_metrics(&1, card_names, deck_cards, total_matches, total_wins))
    |> Enum.sort_by(& &1.iwd, &((&1 || -999) >= (&2 || -999)))
    # Exclude unknown arena_ids — cards not in any card table produce nil card_name
    # and have no meaningful data to display.
    |> Enum.reject(&is_nil(&1.card_name))
  end

  defp deck_match_totals(mtga_deck_id) do
    %{total: total, wins: wins} =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> select([mr], %{
        total: count(),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", mr.won))
      })
      |> Repo.one()

    {total || 0, wins || 0}
  end

  # Tokens are not deck cards — MTGA emits draw annotations when tokens
  # are created during play, but their per-card metrics are meaningless.
  defp exclude_token_rows(aggregates) do
    arena_ids = Enum.map(aggregates, & &1.arena_id)
    token_ids = Scry2.Cards.token_arena_ids(arena_ids)
    Enum.reject(aggregates, &MapSet.member?(token_ids, &1.arena_id))
  end

  defp build_card_metrics(row, card_names, deck_cards, total_matches, total_wins) do
    gnd_games = max(total_matches - row.gih_games, 0)
    gnd_wins = max(total_wins - row.gih_wins, 0)

    oh_wr = win_rate(row.oh_wins, row.oh_games)
    gih_wr = win_rate(row.gih_wins, row.gih_games)
    gd_wr = win_rate(row.gd_wins, row.gd_games)
    gnd_wr = win_rate(gnd_wins, gnd_games)

    iwd =
      if gih_wr && gnd_wr do
        Float.round(gih_wr - gnd_wr, 1)
      end

    %{
      card_arena_id: row.arena_id,
      card_name: Map.get(card_names, row.arena_id),
      copies: Map.get(deck_cards, row.arena_id, 0),
      oh_wr: oh_wr,
      oh_games: row.oh_games,
      gih_wr: gih_wr,
      gih_games: row.gih_games,
      gd_wr: gd_wr,
      gd_games: row.gd_games,
      gnd_wr: gnd_wr,
      gnd_games: gnd_games,
      iwd: iwd,
      community: nil
    }
  end

  # ── Writes ────────────────────────────────────────────────────────────────

  @doc """
  Atomically increments the bo1/bo3 win or loss counter on the deck row.

  Called by `DeckProjection` on every `match_completed` event. Uses
  `Repo.update_all` for an atomic increment — no read-modify-write race.
  No-op if the deck row does not exist (draft decks without a submission).
  """
  def increment_deck_result_counters!(mtga_deck_id, won, format_type, num_games)
      when is_binary(mtga_deck_id) and is_boolean(won) do
    bo3 = format_type == "Traditional" or (is_integer(num_games) and num_games > 1)

    {wins_field, losses_field} =
      if bo3, do: {:bo3_wins, :bo3_losses}, else: {:bo1_wins, :bo1_losses}

    {field, delta} = if won, do: {wins_field, 1}, else: {losses_field, 1}

    from(d in Deck, where: d.mtga_deck_id == ^mtga_deck_id)
    |> Repo.update_all(inc: [{field, delta}])

    :ok
  end

  @doc """
  Upserts a deck by `mtga_deck_id`. Idempotent per ADR-016.

  When `:current_main_deck` is present in the attrs, also stamps
  `composition_hash` (so `find_by_composition/1` is O(1) indexed lookup
  instead of a full-table Elixir scan).
  """
  def upsert_deck!(attrs) do
    attrs = attrs |> Map.new() |> maybe_stamp_composition_hash()
    mtga_deck_id = attrs[:mtga_deck_id]

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
  Updates the curation flags (`:starred`, `:archived`) on a deck. Used by
  both the LiveView toggles and by `DeckProjection` when auto-archiving on
  MTGA deletion. Broadcasts `decks:updates` on success.
  """
  @spec update_deck_flags!(Deck.t(), map()) :: Deck.t()
  def update_deck_flags!(%Deck{} = deck, attrs) do
    updated =
      deck
      |> Deck.flags_changeset(attrs)
      |> Repo.update!()

    broadcast_update(updated.mtga_deck_id)
    updated
  end

  @doc """
  Flips the `starred` flag on the deck with the given `mtga_deck_id`.
  Returns the updated deck, or `nil` if no deck exists for that id.
  """
  @spec toggle_starred!(String.t()) :: Deck.t() | nil
  def toggle_starred!(mtga_deck_id) when is_binary(mtga_deck_id) do
    case get_deck(mtga_deck_id) do
      nil -> nil
      deck -> update_deck_flags!(deck, %{starred: !deck.starred})
    end
  end

  @doc """
  Flips the `archived` flag on the deck with the given `mtga_deck_id`.
  Returns the updated deck, or `nil` if no deck exists for that id.
  """
  @spec toggle_archived!(String.t()) :: Deck.t() | nil
  def toggle_archived!(mtga_deck_id) when is_binary(mtga_deck_id) do
    case get_deck(mtga_deck_id) do
      nil -> nil
      deck -> update_deck_flags!(deck, %{archived: !deck.archived})
    end
  end

  @doc """
  Returns the `mtga_deck_id` of the deck whose main-deck composition
  matches `main_deck`, or nil. Uses the indexed `composition_hash`
  column to avoid scanning every deck.

  `main_deck` is a list of card maps with `arena_id` and `count` keys
  (string- or atom-keyed). Returns nil for empty input.
  """
  @spec find_mtga_deck_id_by_composition(list()) :: String.t() | nil
  def find_mtga_deck_id_by_composition([]), do: nil

  def find_mtga_deck_id_by_composition(main_deck) when is_list(main_deck) do
    case composition_hash(main_deck) do
      nil ->
        nil

      hash ->
        Deck
        |> where([d], d.composition_hash == ^hash)
        |> select([d], {d.mtga_deck_id, d.current_main_deck})
        |> Repo.all()
        |> Enum.find_value(fn {mtga_deck_id, current_main_deck} ->
          # Hash collisions are possible (phash2 is 27-bit on 64-bit ERTS).
          # Verify the actual composition matches before returning.
          if same_composition?(main_deck, current_main_deck), do: mtga_deck_id
        end)
    end
  end

  @doc """
  Hash of a main-deck composition. `nil` if the input has no resolvable
  arena_id/count pairs. Stable across BEAM versions per `:erlang.phash2/1`.
  """
  @spec composition_hash(list() | nil) :: integer() | nil
  def composition_hash(nil), do: nil
  def composition_hash([]), do: nil

  def composition_hash(cards) when is_list(cards) do
    pairs =
      cards
      |> Enum.map(&card_arena_count_pair/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case pairs do
      [] -> nil
      sorted -> :erlang.phash2(sorted)
    end
  end

  defp card_arena_count_pair(card) when is_map(card) do
    arena_id = card["arena_id"] || card[:arena_id]
    count = card["count"] || card[:count]
    if arena_id && count, do: {arena_id, count}, else: nil
  end

  defp card_arena_count_pair(_), do: nil

  defp same_composition?(submitted, %{"cards" => cards}) when is_list(cards) do
    sort_pairs(submitted) == sort_pairs(cards)
  end

  defp same_composition?(_, _), do: false

  defp sort_pairs(cards) do
    cards
    |> Enum.map(&card_arena_count_pair/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp maybe_stamp_composition_hash(%{current_main_deck: main_deck} = attrs)
       when is_map(main_deck) do
    cards = main_deck["cards"] || main_deck[:cards] || []
    Map.put(attrs, :composition_hash, composition_hash(cards))
  end

  defp maybe_stamp_composition_hash(attrs), do: attrs

  @doc """
  Upserts a match result by `(mtga_deck_id, mtga_match_id)`. Idempotent per ADR-016.
  """
  def upsert_match_result!(attrs) do
    attrs = Map.new(attrs)
    mtga_deck_id = attrs[:mtga_deck_id]
    mtga_match_id = attrs[:mtga_match_id]

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
  Merge a memory observation snapshot into the `decks_match_results` row
  identified by `mtga_match_id`. Memory-wins-when-present: nil fields in
  the snapshot are dropped before the update so log-derived non-nil
  values are preserved. Broadcasts `{:deck_updated, mtga_deck_id}` on
  `decks:updates` on success (gated by SilentMode).

  No-op when the snapshot has no enrichable fields populated, or when no
  match_result row exists for the given `mtga_match_id`.
  """
  @spec merge_match_result_observation(Snapshot.t()) ::
          {:ok, MatchResult.t()} | {:error, Ecto.Changeset.t()} | :ok
  def merge_match_result_observation(%Snapshot{} = snapshot) do
    attrs = merge_match_result_observation_attrs(snapshot)

    if map_size(attrs) == 0 do
      :ok
    else
      case Repo.get_by(MatchResult, mtga_match_id: snapshot.mtga_match_id) do
        nil ->
          # Race: memory `live_match:final` can arrive before the log-derived
          # match_result row exists. Expected during normal flow.
          Log.info(:ingester, fn ->
            "merge_match_result_observation: no match_result for mtga_match_id=#{snapshot.mtga_match_id}"
          end)

          :ok

        %MatchResult{} = result ->
          case result |> MatchResult.changeset(attrs) |> Repo.update() do
            {:ok, updated} ->
              broadcast_update(updated.mtga_deck_id)
              {:ok, updated}

            {:error, changeset} = error ->
              Log.error(
                :ingester,
                "merge_match_result_observation: changeset error: #{inspect(changeset.errors)}"
              )

              error
          end
      end
    end
  end

  defp merge_match_result_observation_attrs(%Snapshot{} = snapshot) do
    %{
      opponent_screen_name: snapshot.opponent_screen_name,
      opponent_rank:
        RankFormat.compose(
          RankClass.name(snapshot.opponent_ranking_class),
          snapshot.opponent_ranking_tier
        ),
      opponent_rank_mythic_percentile: snapshot.opponent_mythic_percentile,
      opponent_rank_mythic_placement: snapshot.opponent_mythic_placement,
      player_rank:
        RankFormat.compose(
          RankClass.name(snapshot.local_ranking_class),
          snapshot.local_ranking_tier
        )
      # Note: local_mythic_percentile/placement deliberately not persisted —
      # the Ranks context owns the player's mythic progression with richer
      # point-in-time data than this single observation.
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
    mtga_deck_id = attrs[:mtga_deck_id]
    mtga_match_id = attrs[:mtga_match_id]
    game_number = attrs[:game_number]

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
  defp maybe_filter_by_player(query, _player_id), do: query

  defp maybe_filter_played_in_sql(query, false), do: query

  defp maybe_filter_played_in_sql(query, true) do
    where(query, [d], d.bo1_wins + d.bo1_losses + d.bo3_wins + d.bo3_losses > 0)
  end

  defp filter_by_status(query, :all), do: query
  defp filter_by_status(query, :active), do: where(query, [d], d.archived == false)
  defp filter_by_status(query, :archived), do: where(query, [d], d.archived == true)

  defp maybe_filter_starred(query, false), do: query
  defp maybe_filter_starred(query, true), do: where(query, [d], d.starred == true)

  # SQL aggregate for bo1 or bo3 base stats — one query, no full-row load.
  # on_play = nil is treated as on_draw (matches Enum.reject behaviour).
  defp aggregate_deck_format_stats(mtga_deck_id, format) do
    row =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> apply_format_filter(format)
      |> select([mr], %{
        total: count(),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", mr.won)),
        on_play_total: sum(fragment("CASE WHEN ? IS TRUE THEN 1 ELSE 0 END", mr.on_play)),
        on_play_wins:
          sum(fragment("CASE WHEN ? IS TRUE AND ? THEN 1 ELSE 0 END", mr.on_play, mr.won))
      })
      |> Repo.one()

    total = row.total || 0
    wins = row.wins || 0
    on_play_total = row.on_play_total || 0
    on_play_wins = row.on_play_wins || 0
    on_draw_total = max(total - on_play_total, 0)
    on_draw_wins = max(wins - on_play_wins, 0)

    %{
      total: total,
      wins: wins,
      losses: total - wins,
      win_rate: win_rate(wins, total),
      on_play_total: on_play_total,
      on_play_wins: on_play_wins,
      on_play_win_rate: win_rate(on_play_wins, on_play_total),
      on_draw_total: on_draw_total,
      on_draw_wins: on_draw_wins,
      on_draw_win_rate: win_rate(on_draw_wins, on_draw_total)
    }
  end

  # Bo3 stats extend the base aggregate with game1 vs games-2/3 win rates.
  # Those require per-match game_results JSON, so a lean row query is still
  # needed — but it only selects the two fields used by bo3_game_split/1.
  defp aggregate_deck_bo3_stats(mtga_deck_id) do
    base = aggregate_deck_format_stats(mtga_deck_id, :bo3)

    game_rows =
      MatchResult
      |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
      |> apply_format_filter(:bo3)
      |> select([mr], %{game_results: mr.game_results})
      |> Repo.all()

    {game1_wins, game1_total, later_wins, later_total} = bo3_game_split(game_rows)

    Map.merge(base, %{
      game1_total: game1_total,
      game1_wins: game1_wins,
      game1_win_rate: win_rate(game1_wins, game1_total),
      games_2_3_total: later_total,
      games_2_3_wins: later_wins,
      games_2_3_win_rate: win_rate(later_wins, later_total)
    })
  end

  defp bo3_game_split(rows) do
    Enum.reduce(rows, {0, 0, 0, 0}, fn row, acc ->
      {game1_wins, game1_total, later_wins, later_total} = acc
      game_results = (row.game_results && row.game_results["results"]) || []
      game1 = Enum.find(game_results, &(&1["game"] == 1))
      later = Enum.filter(game_results, &(&1["game"] > 1))

      {
        if(game1 && game1["won"], do: game1_wins + 1, else: game1_wins),
        if(game1, do: game1_total + 1, else: game1_total),
        later_wins + Enum.count(later, & &1["won"]),
        later_total + length(later)
      }
    end)
  end

  defp deck_rolling_win_rate(mtga_deck_id, format, days, now) do
    rows =
      MatchResult
      |> where(
        [mr],
        mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won) and not is_nil(mr.started_at)
      )
      |> apply_format_filter(format)
      |> order_by([mr], asc: mr.started_at)
      |> select([mr], %{started_at: mr.started_at, won: mr.won})
      |> Repo.all()

    case days do
      nil ->
        RollingWindow.cumulative_points(rows)

      window_days when is_integer(window_days) and window_days > 0 ->
        rows
        |> RollingWindow.rolling_points(window_days)
        |> RollingWindow.filter_to_display_window(window_days, now)
    end
  end

  # A match is BO3 if format_type is "Traditional" (ranked queues) OR
  # num_games > 1 (DirectGame BO3 challenges, where format_type is nil).
  defp bo3?(%MatchResult{format_type: "Traditional"}), do: true

  defp bo3?(%MatchResult{num_games: num_games}) when is_integer(num_games) and num_games > 1,
    do: true

  defp bo3?(_), do: false

  defp win_rate(wins, total), do: Scry2.Analytics.WinRate.percent(wins, total)

  # Per-card presence aggregates for `card_performance/1` — computed in SQL.
  # Replaces the prior `build_card_match_presence/1` which materialised every
  # mulligan hand's `hand_arena_ids` JSON in Elixir and built a
  # `{arena_id, match_id} => %{in_opener, drawn, won}` map.
  #
  # The CTE:
  #   1. Expands each kept hand's `hand_arena_ids["cards"]` via `json_each`.
  #   2. Unions with self-draw rows from `decks_cards_drawn`.
  #   3. Deduplicates per `(arena_id, mtga_match_id)` so a card present in
  #      both the opener and as a later draw counts once in GIH stats.
  #   4. Aggregates per `arena_id` into oh/gd/gih game and win counts.
  #
  # Returns `[%{arena_id, oh_games, oh_wins, gd_games, gd_wins, gih_games, gih_wins}, ...]`.
  defp card_match_aggregates(mtga_deck_id) do
    sql = """
    WITH per_match AS (
      SELECT arena_id, mtga_match_id,
             MAX(in_opener) AS in_opener,
             MAX(drawn)     AS drawn,
             MAX(won)       AS won
      FROM (
        SELECT CAST(je.value AS INTEGER) AS arena_id,
               mh.mtga_match_id,
               1 AS in_opener,
               0 AS drawn,
               CASE WHEN mh.match_won THEN 1 ELSE 0 END AS won
        FROM decks_mulligan_hands AS mh,
             json_each(json_extract(mh.hand_arena_ids, '$.cards')) AS je
        WHERE mh.mtga_deck_id = ?1
          AND mh.decision = 'kept'
          AND mh.match_won IS NOT NULL

        UNION ALL

        SELECT card_arena_id AS arena_id,
               mtga_match_id,
               0 AS in_opener,
               1 AS drawn,
               CASE WHEN match_won THEN 1 ELSE 0 END AS won
        FROM decks_cards_drawn
        WHERE mtga_deck_id = ?1
          AND match_won IS NOT NULL
          AND is_self_draw = 1
      )
      GROUP BY arena_id, mtga_match_id
    )
    SELECT arena_id,
           SUM(in_opener)                                         AS oh_games,
           SUM(in_opener * won)                                   AS oh_wins,
           SUM(CASE WHEN drawn = 1 AND in_opener = 0 THEN 1 ELSE 0 END)             AS gd_games,
           SUM(CASE WHEN drawn = 1 AND in_opener = 0 AND won = 1 THEN 1 ELSE 0 END) AS gd_wins,
           COUNT(*)                                               AS gih_games,
           SUM(won)                                               AS gih_wins
    FROM per_match
    GROUP BY arena_id
    """

    {:ok, %{rows: rows}} = Repo.query(sql, [mtga_deck_id])

    Enum.map(rows, fn [arena_id, oh_games, oh_wins, gd_games, gd_wins, gih_games, gih_wins] ->
      %{
        arena_id: arena_id,
        oh_games: as_int(oh_games),
        oh_wins: as_int(oh_wins),
        gd_games: as_int(gd_games),
        gd_wins: as_int(gd_wins),
        gih_games: as_int(gih_games),
        gih_wins: as_int(gih_wins)
      }
    end)
  end

  defp as_int(nil), do: 0
  defp as_int(int) when is_integer(int), do: int

  # Extracts `%{arena_id => count}` from a deck's main deck + sideboard.
  defp deck_card_counts(nil), do: %{}

  defp deck_card_counts(%Deck{} = deck) do
    main = (deck.current_main_deck && deck.current_main_deck["cards"]) || []
    side = (deck.current_sideboard && deck.current_sideboard["cards"]) || []

    (main ++ side)
    |> Enum.group_by(fn card -> card["arena_id"] || card[:arena_id] end)
    |> Map.new(fn {arena_id, cards} ->
      {arena_id, Enum.sum(Enum.map(cards, fn card -> card["count"] || card[:count] || 1 end))}
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
    unless Scry2.Events.SilentMode.silent?() do
      Topics.broadcast(Topics.decks_updates(), {:deck_updated, mtga_deck_id})
    end
  end
end
