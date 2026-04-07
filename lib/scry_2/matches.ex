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

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  defp broadcast_update(match_id) do
    Topics.broadcast(Topics.matches_updates(), {:match_updated, match_id})
  end
end
