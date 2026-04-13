defmodule Scry2.Matches do
  @moduledoc """
  Context module for recorded matches, games, and deck submissions.

  Owns tables: `matches_matches`, `matches_games`, `matches_deck_submissions`.

  PubSub role:
    * subscribes to `"domain:events"` (via `Scry2.Matches.MatchProjection`)
    * broadcasts `"matches:updates"` after any mutation

  All upserts target MTGA-provided ids (`mtga_match_id`, `mtga_deck_id`)
  for idempotency — see ADR-016.
  """

  import Ecto.Query

  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Returns the most recent matches, newest first.

  Options: `:limit`, `:offset`, `:player_id`, `:format`, `:bo`, `:won`.
  """
  def list_matches(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)
    offset_count = Keyword.get(opts, :offset, 0)

    opts
    |> base_query()
    |> order_by([m], desc: m.started_at)
    |> limit(^limit_count)
    |> offset(^offset_count)
    |> Repo.all()
  end

  @doc "Returns matches that ended within the given time range, ordered by ended_at ascending."
  def list_matches_in_range(started_after, ended_before) do
    Match
    |> where([m], m.ended_at >= ^started_after and m.ended_at <= ^ended_before)
    |> order_by([m], asc: m.ended_at)
    |> Repo.all()
  end

  @doc "Returns the match with its games and deck submissions preloaded."
  def get_match_with_associations(id) do
    Match
    |> Repo.get(id)
    |> Repo.preload([:games, :deck_submissions])
  end

  @doc "Returns the match with the given MTGA id and optional player_id, or nil."
  def get_by_mtga_id(mtga_match_id, player_id \\ nil) when is_binary(mtga_match_id) do
    Match
    |> where([m], m.mtga_match_id == ^mtga_match_id)
    |> maybe_filter_by_player(player_id)
    |> Repo.one()
  end

  @doc """
  Inserts a new match or updates the existing one with the same
  `(player_id, mtga_match_id)`. Idempotent per ADR-016.
  """
  def upsert_match!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_match_id] || attrs["mtga_match_id"]
    player_id = attrs[:player_id] || attrs["player_id"]

    match =
      case get_by_mtga_id(mtga_id, player_id) do
        nil -> %Match{}
        existing -> existing
      end
      |> Match.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(match.id)
    match
  end

  @doc """
  Upserts a single game under a match by the composite key
  `(match_id, game_number)`. Idempotent per ADR-016 — reprocessing the
  same event range yields identical rows.
  """
  def upsert_game!(attrs) do
    attrs = Map.new(attrs)
    match_id = attrs[:match_id] || attrs["match_id"]
    game_number = attrs[:game_number] || attrs["game_number"]

    game =
      case Repo.get_by(Game, match_id: match_id, game_number: game_number) do
        nil -> %Game{}
        existing -> existing
      end
      |> Game.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(game.match_id)
    game
  end

  @doc """
  Upserts a deck submission by `mtga_deck_id`. Idempotent per ADR-016.
  """
  def upsert_deck_submission!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_deck_id] || attrs["mtga_deck_id"]

    submission =
      case Repo.get_by(DeckSubmission, mtga_deck_id: mtga_id) do
        nil -> %DeckSubmission{}
        existing -> existing
      end
      |> DeckSubmission.changeset(attrs)
      |> Repo.insert_or_update!()

    if submission.match_id, do: broadcast_update(submission.match_id)
    submission
  end

  @doc "Returns the total number of recorded matches. Accepts same filter opts as list_matches."
  def count(opts \\ []) do
    opts
    |> base_query()
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns aggregate match statistics, optionally filtered by player_id.

  Returns a map with:
    * `:total` — total matches
    * `:wins` — matches won
    * `:losses` — matches lost
    * `:win_rate` — float 0.0–100.0, or nil if no completed matches
    * `:avg_turns` — average total_turns per match, or nil
    * `:avg_mulligans` — average total_mulligans per match, or nil
    * `:by_format` — list of `%{key: string, total: int, wins: int, win_rate: float}`
    * `:by_deck_colors` — same shape
    * `:by_deck_name` — same shape
  """
  def aggregate_stats(opts \\ []) do
    base =
      opts
      |> base_query()
      |> where([m], not is_nil(m.won))

    overall = overall_stats(base)
    by_format = breakdown_by(base, :format)
    by_deck_colors = breakdown_by(base, :deck_colors)
    by_deck_name = breakdown_by(base, :deck_name)

    by_on_play = breakdown_by(base, :on_play)

    Map.merge(overall, %{
      by_format: by_format,
      by_deck_colors: by_deck_colors,
      by_deck_name: by_deck_name,
      by_on_play: by_on_play
    })
  end

  defp overall_stats(query) do
    result =
      query
      |> select([m], %{
        total: count(m.id),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won)),
        avg_turns: avg(m.total_turns),
        avg_mulligans: avg(m.total_mulligans)
      })
      |> Repo.one()

    wins = result.wins || 0
    total = result.total || 0

    %{
      total: total,
      wins: wins,
      losses: total - wins,
      win_rate: if(total > 0, do: Float.round(wins / total * 100, 1)),
      avg_turns: if(result.avg_turns, do: Float.round(result.avg_turns / 1, 1)),
      avg_mulligans: if(result.avg_mulligans, do: Float.round(result.avg_mulligans / 1, 1))
    }
  end

  defp breakdown_by(query, field) do
    query
    |> where([m], not is_nil(field(m, ^field)))
    |> exclude_blank_strings(field)
    |> group_by([m], field(m, ^field))
    |> select([m], %{
      key: field(m, ^field),
      total: count(m.id),
      wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won)),
      last_played_at: max(m.started_at)
    })
    |> order_by([m], desc: max(m.started_at))
    |> Repo.all()
    |> Enum.map(fn row ->
      wins = row.wins || 0

      %{
        key: row.key,
        total: row.total,
        wins: wins,
        losses: row.total - wins,
        win_rate: Float.round(wins / row.total * 100, 1),
        last_played_at: row.last_played_at
      }
    end)
  end

  @boolean_fields [:on_play, :won]

  defp exclude_blank_strings(query, field) when field in @boolean_fields, do: query
  defp exclude_blank_strings(query, field), do: where(query, [m], field(m, ^field) != "")

  @doc "Returns a map of mtga_match_id => won for the given MTGA match IDs."
  def outcomes_by_mtga_ids(mtga_match_ids) when is_list(mtga_match_ids) do
    Match
    |> where([m], m.mtga_match_id in ^mtga_match_ids)
    |> select([m], {m.mtga_match_id, m.won})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns cumulative win rate data points for the chart, respecting filter opts.

  Returns `[%{timestamp: iso8601, win_rate: float, wins: int, total: int}]`.
  """
  def cumulative_win_rate(opts \\ []) do
    opts
    |> base_query()
    |> where([m], not is_nil(m.won))
    |> order_by([m], asc: m.started_at)
    |> select([m], %{started_at: m.started_at, won: m.won})
    |> Repo.all()
    |> Enum.reduce({0, 0, []}, fn match, {wins, total, acc} ->
      wins = if match.won, do: wins + 1, else: wins
      total = total + 1
      rate = Float.round(wins / total * 100, 1)

      point = %{
        timestamp: DateTime.to_iso8601(match.started_at),
        win_rate: rate,
        wins: wins,
        total: total
      }

      {wins, total, [point | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  @doc """
  Returns all matches against a specific opponent, excluding a given match.
  """
  def opponent_matches(opponent_screen_name, opts \\ []) do
    exclude_id = Keyword.get(opts, :exclude_match_id)
    player_id = Keyword.get(opts, :player_id)

    Match
    |> maybe_filter_by_player(player_id)
    |> where([m], m.opponent_screen_name == ^opponent_screen_name)
    |> then(fn query ->
      if exclude_id, do: where(query, [m], m.id != ^exclude_id), else: query
    end)
    |> order_by([m], desc: m.started_at)
    |> Repo.all()
  end

  @doc """
  Returns match counts grouped by format for filter badge display.
  Respects `:player_id`, `:bo`, `:won` filters (not `:format` — that's what we're counting).
  """
  def format_counts(opts \\ []) do
    opts
    |> Keyword.delete(:format)
    |> base_query()
    |> where([m], not is_nil(m.format) and m.format != "")
    |> group_by([m], m.format)
    |> select([m], {m.format, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns the last `count` completed match results, newest first.

  Returns `[%{won: boolean, started_at: DateTime.t()}]`.
  """
  def recent_results(opts \\ []) do
    count = Keyword.get(opts, :count, 10)

    opts
    |> base_query()
    |> where([m], not is_nil(m.won))
    |> order_by([m], desc: m.started_at)
    |> limit(^count)
    |> select([m], %{won: m.won, started_at: m.started_at})
    |> Repo.all()
  end

  @doc """
  Returns the current win or loss streak as `{:win | :loss, count}`.

  Scans completed matches newest-first until the streak breaks.
  Returns `{:none, 0}` if no completed matches exist.
  """
  def current_streak(opts \\ []) do
    matches =
      opts
      |> base_query()
      |> where([m], not is_nil(m.won))
      |> order_by([m], desc: m.started_at)
      |> select([m], m.won)
      |> Repo.all()

    case matches do
      [] ->
        {:none, 0}

      [first | rest] ->
        streak_type = if first, do: :win, else: :loss
        streak_count = 1 + length(Enum.take_while(rest, fn won -> won == first end))
        {streak_type, streak_count}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp base_query(opts) do
    Match
    |> maybe_filter_by_player(Keyword.get(opts, :player_id))
    |> maybe_filter_by_format(Keyword.get(opts, :format))
    |> maybe_filter_by_bo(Keyword.get(opts, :bo))
    |> maybe_filter_by_won(Keyword.get(opts, :won))
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  defp maybe_filter_by_format(query, nil), do: query
  defp maybe_filter_by_format(query, format), do: where(query, [m], m.format == ^format)

  defp maybe_filter_by_bo(query, nil), do: query
  defp maybe_filter_by_bo(query, "3"), do: where(query, [m], m.format_type == "Traditional")

  defp maybe_filter_by_bo(query, "1"),
    do: where(query, [m], m.format_type != "Traditional" or is_nil(m.format_type))

  defp maybe_filter_by_bo(query, _), do: query

  defp maybe_filter_by_won(query, nil), do: query
  defp maybe_filter_by_won(query, won) when is_boolean(won), do: where(query, [m], m.won == ^won)

  defp broadcast_update(match_id) do
    Topics.broadcast(Topics.matches_updates(), {:match_updated, match_id})
  end
end
