defmodule Scry2.Matches do
  @moduledoc """
  Context module for recorded matches, games, and deck submissions.

  Owns tables: `matches_matches`, `matches_games`, `matches_deck_submissions`.

  PubSub role:
    * subscribes to `"domain:events"` (via `Scry2.Matches.UpdateFromEvent`)
    * broadcasts `"matches:updates"` after any mutation

  All upserts target MTGA-provided ids (`mtga_match_id`, `mtga_deck_id`)
  for idempotency — see ADR-016.
  """

  import Ecto.Query

  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc "Returns the most recent matches, newest first. Optionally filtered by player_id."
  def list_matches(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)
    player_id = Keyword.get(opts, :player_id)

    Match
    |> maybe_filter_by_player(player_id)
    |> order_by([m], desc: m.started_at)
    |> limit(^limit_count)
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

  @doc "Returns the total number of recorded matches. Optionally filtered by player_id."
  def count(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    Match
    |> maybe_filter_by_player(player_id)
    |> Repo.aggregate(:count, :id)
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
    player_id = Keyword.get(opts, :player_id)

    base =
      Match
      |> maybe_filter_by_player(player_id)
      |> where([m], not is_nil(m.won))

    overall = overall_stats(base)
    by_format = breakdown_by(base, :format)
    by_deck_colors = breakdown_by(base, :deck_colors)
    by_deck_name = breakdown_by(base, :deck_name)

    Map.merge(overall, %{
      by_format: by_format,
      by_deck_colors: by_deck_colors,
      by_deck_name: by_deck_name
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
    |> where([m], not is_nil(field(m, ^field)) and field(m, ^field) != "")
    |> group_by([m], field(m, ^field))
    |> select([m], %{
      key: field(m, ^field),
      total: count(m.id),
      wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.won))
    })
    |> order_by([m], desc: count(m.id))
    |> Repo.all()
    |> Enum.map(fn row ->
      wins = row.wins || 0

      %{
        key: row.key,
        total: row.total,
        wins: wins,
        losses: row.total - wins,
        win_rate: Float.round(wins / row.total * 100, 1)
      }
    end)
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  defp broadcast_update(match_id) do
    Topics.broadcast(Topics.matches_updates(), {:match_updated, match_id})
  end
end
